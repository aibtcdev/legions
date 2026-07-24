// ─────────────────────────────────────────────────────────────────────────────
//  news-legion testnet driver.
//
//  WHY THIS EXISTS RATHER THAN THE MCP: the aibtc MCP resolves to whichever
//  network its env is set to, and at time of writing that is MAINNET
//  (networkId 1). Broadcasting this flow through it would sign against real
//  funds. This script pins StacksTestnet explicitly, so it cannot touch
//  mainnet even if the MCP config changes underneath it.
//
//  Every fund-moving call is DENY mode with an exact post-condition. Never
//  Allow: a contract bug or a wrong argument should fail the transaction, not
//  quietly move a different amount.
//
//  Usage:
//    STACKS_MNEMONIC="..." node scripts/flow.mjs <step> [args]
//
//    status                      read the whole legion state, no key needed
//    faucet                      mint 6.9 sBTC to the signer
//    contribute <sats>           fund the pool, receive voting weight
//    propose                     submit the sample week (see WEEK/ENTRIES)
//    vote <yes|no>               vote on the open week
//    veto                        object during the veto window
//    conclude                    work out the outcome and, if passed, pay out
// ─────────────────────────────────────────────────────────────────────────────
import {
  makeContractCall, broadcastTransaction, AnchorMode, PostConditionMode,
  FungibleConditionCode, createAssetInfo, makeStandardFungiblePostCondition,
  makeContractFungiblePostCondition,
  uintCV, boolCV, listCV, tupleCV, bufferCV, stringAsciiCV, standardPrincipalCV,
  callReadOnlyFunction, cvToJSON, getAddressFromPrivateKey, TransactionVersion,
} from '@stacks/transactions';
import { StacksTestnet } from '@stacks/network';
import { generateWallet } from '@stacks/wallet-sdk';

const API = process.env.STACKS_API || 'https://api.testnet.hiro.so';
const network = new StacksTestnet({ url: API });

const LEGION = 'STGX5YP51NKM69ZMP6DVB6GAJAANCG5WB3718KD9'; // v3, block 4049423
const GOV = 'news-gov';
const TREASURY = 'news-treasury';

const SBTC = {
  address: 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2',
  name: 'sbtc-token',
  asset: 'sbtc-token',
};

// The sample week. Recipients are agent-07 and agent-08, who never transact:
// they only receive.
const WEEK = '2026-07-20';
const TITLE = 'Week of 2026-07-20: 50 signals from 2 correspondents';
const DESCRIPTION =
  'agent-07 30 signals, agent-08 20. Tallied across the week 7 inscribed briefs; ' +
  'BTC addresses resolved to Stacks principals via aibtc.com/api/agents.';
const INSCRIPTIONS = [
  '33edd63ed94e8a7613cc573b8d08ee8befcb8ef88b85fbaf1647d5b91b3b195ei0',
];
const ENTRIES = [
  { recipient: 'ST34Q5MVC410NTEK8G00G2QZ1JTBB2WJTNABTE6RA', signals: 30 },
  { recipient: 'ST1QQ1NJMM3MH73X2W2DD7K9K2G9CHW00D9FVX7PD', signals: 20 },
];

async function key() {
  const phrase = process.env.STACKS_MNEMONIC;
  if (!phrase) throw new Error('set STACKS_MNEMONIC');
  const w = await generateWallet({ secretKey: phrase.trim(), password: '' });
  return w.accounts[0].stxPrivateKey;
}

const addrOf = (pk) => getAddressFromPrivateKey(pk, TransactionVersion.Testnet);

async function ro(contract, fn, args = []) {
  const r = await callReadOnlyFunction({
    contractAddress: LEGION, contractName: contract, functionName: fn,
    functionArgs: args, network, senderAddress: LEGION,
  });
  return cvToJSON(r);
}

async function send({ contract, fn, args, postConditions = [], senderKey }) {
  const tx = await makeContractCall({
    contractAddress: LEGION, contractName: contract, functionName: fn,
    functionArgs: args, senderKey, network,
    anchorMode: AnchorMode.Any,
    // DENY plus an exact condition: the transaction may move precisely what we
    // declared and nothing else.
    postConditionMode: PostConditionMode.Deny,
    postConditions,
    fee: 20000n,
  });
  const res = await broadcastTransaction(tx, network);
  if (res.error) throw new Error(`${res.error} ${res.reason || ''} ${JSON.stringify(res.reason_data || {})}`);
  const txid = res.txid || res;
  console.log(`broadcast ${fn}: ${txid}`);
  console.log(`  https://explorer.hiro.so/txid/${txid}?chain=testnet`);
  return txid;
}

async function status() {
  const [mode, gov, bal, weight, bond, nextProp, brief] = await Promise.all([
    ro(GOV, 'get-timing-mode'),
    ro(TREASURY, 'get-gov'),
    ro(TREASURY, 'get-balance'),
    ro(GOV, 'get-total-weight'),
    ro(GOV, 'quote-bond'),
    ro(GOV, 'get-next-propose-height'),
    ro(GOV, 'get-brief', [stringAsciiCV(WEEK)]),
  ]);
  const tip = await fetch(`${API}/extended/v2/blocks?limit=1`).then((r) => r.json());
  const height = tip.results[0].height;

  console.log(`legion        ${LEGION}`);
  console.log(`timing mode   ${mode.value}`);
  console.log(`gov wired     ${gov.value?.value ?? gov.value}`);
  console.log(`pool          ${bal.value} sats`);
  console.log(`total weight  ${weight.value}`);
  console.log(`bond now      ${bond.value}`);
  console.log(`stacks height ${height}`);
  console.log(`next propose  ${nextProp.value} ${Number(nextProp.value) <= height ? '(open)' : `(in ${Number(nextProp.value) - height} blocks)`}`);

  const b = brief.value?.value;
  if (!b) { console.log(`week ${WEEK}    not proposed`); return; }
  const g = (k) => b[k]?.value?.value ?? b[k]?.value;
  const STATUS = ['OPEN', 'PASSED', 'FAILED', 'EXPIRED'];
  const voteEnd = Number(g('voteEnd'));
  console.log(`week ${WEEK}`);
  console.log(`  status      ${STATUS[Number(g('status'))]}${g('reason') ? ` (${g('reason')})` : ''}`);
  console.log(`  draw        ${g('draw')} sats, snapshotted at propose`);
  console.log(`  proposer    ${g('proposer')}`);
  console.log(`  signals     ${g('totalSignals')} across ${g('entryCount')} correspondents`);
  console.log(`  bond        ${g('bond')}`);
  console.log(`  yes/no/veto ${g('yesWeight')} / ${g('noWeight')} / ${g('vetoWeight')}  (${g('voterCount')} voters)`);
  console.log(`  eligible    ${g('eligibleSnapshot')}`);
  console.log(`  voteEnd     ${voteEnd} ${height < voteEnd ? `(voting, ${voteEnd - height} blocks left)` : '(voting closed)'}`);
  console.log(`  settle at   ${voteEnd + 12} ${height >= voteEnd + 12 ? '(ready)' : `(in ${voteEnd + 12 - height} blocks)`}`);
}

const step = process.argv[2];
const arg = process.argv[3];

if (step === 'status') {
  await status();
} else {
  const pk = await key();
  const me = addrOf(pk);
  console.log(`signer ${me}`);

  if (step === 'faucet') {
    const tx = await makeContractCall({
      contractAddress: SBTC.address, contractName: SBTC.name,
      functionName: 'faucet', functionArgs: [], senderKey: pk, network,
      anchorMode: AnchorMode.Any, postConditionMode: PostConditionMode.Allow,
      fee: 20000n,
    });
    const res = await broadcastTransaction(tx, network);
    console.log(`faucet: ${res.txid || JSON.stringify(res)}`);
  } else if (step === 'contribute') {
    const amount = BigInt(arg);
    // contribute pulls exactly `amount` sBTC from the signer, nothing else.
    await send({
      contract: GOV, fn: 'contribute', args: [uintCV(amount)], senderKey: pk,
      postConditions: [makeStandardFungiblePostCondition(
        me, FungibleConditionCode.Equal, amount,
        createAssetInfo(SBTC.address, SBTC.name, SBTC.asset),
      )],
    });
  } else if (step === 'propose') {
    await send({
      contract: GOV, fn: 'propose-brief', senderKey: pk,
      args: [
        stringAsciiCV(WEEK),
        stringAsciiCV(TITLE),
        stringAsciiCV(DESCRIPTION),
        listCV(INSCRIPTIONS.map((i) => bufferCV(Buffer.from(i, 'ascii')))),
        listCV(ENTRIES.map((e) => tupleCV({
          recipient: standardPrincipalCV(e.recipient),
          signals: uintCV(e.signals),
        }))),
      ],
      // No sBTC moves on propose: the bond is weight, not sats.
      postConditions: [],
    });
  } else if (step === 'vote') {
    await send({
      contract: GOV, fn: 'vote', senderKey: pk,
      args: [stringAsciiCV(WEEK), boolCV(arg === 'yes')], postConditions: [],
    });
  } else if (step === 'veto') {
    await send({ contract: GOV, fn: 'veto', args: [stringAsciiCV(WEEK)], senderKey: pk, postConditions: [] });
  } else if (step === 'conclude') {
    // settle moves sBTC OUT OF THE TREASURY CONTRACT to each correspondent and
    // the proposer, not out of the signer. A condition on the signer therefore
    // covers nothing, and in DENY mode every transfer must be covered, so the
    // first attempt aborted with abort_by_post_condition. The correct condition
    // is on the treasury contract principal, for exactly the draw.
    //
    // Post-conditions aggregate per (principal, asset), so one condition covers
    // all three transfers: entries + proposer fee == the draw exactly.
    // The draw is snapshotted on the brief, not recomputed from the pool. And
    // perSignal is floored, so the real spend is perSignal * totalSignals,
    // which can be a few sats under the draw.
    const brief = await ro(GOV, 'get-brief', [stringAsciiCV(WEEK)]);
    const b = brief.value.value;
    const draw = BigInt(b.draw.value);
    const totalSignals = BigInt(b.totalSignals.value);
    const spend = (draw / totalSignals) * totalSignals;
    console.log(`draw ${draw} over ${totalSignals} signals -> treasury sends exactly ${spend}`);
    await send({
      contract: GOV, fn: 'conclude', args: [stringAsciiCV(WEEK)], senderKey: pk,
      postConditions: [makeContractFungiblePostCondition(
        LEGION, TREASURY, FungibleConditionCode.Equal, spend,
        createAssetInfo(SBTC.address, SBTC.name, SBTC.asset),
      )],
    });
  } else {
    console.error('unknown step. try: status | faucet | contribute <sats> | propose | vote yes|no | veto | settle');
    process.exit(2);
  }
}
