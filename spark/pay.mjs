// ─────────────────────────────────────────────────────────────────────────────
//  Option B payment — the agent settles an inference bill through the Legion's
//  own fee rail, so paying the model also taxes the treasury 8%.
//
//  x402-stacks@2.0.3 can only carry a SIP-010 `transfer` as X-PAYMENT, so it
//  CANNOT emit our `legion-fees.route` call. Under Option B the agent broadcasts
//  the route call ITSELF (here), waits for confirmation, and hands the txid to
//  the gateway, which verifies it on-chain. The relay is out of the fee path.
//
//  route(ft <sip010>, amount uint, to principal):
//     pulls `amount` sBTC from tx-sender → 8% to legion-treasury, 92% to `to`.
//  So tx-sender's sBTC decreases by exactly `amount` → one exact FT
//  post-condition in DENY mode (never Allow).
// ─────────────────────────────────────────────────────────────────────────────
import {
  makeContractCall, broadcastTransaction, AnchorMode, PostConditionMode,
  FungibleConditionCode, createAssetInfo, makeStandardFungiblePostCondition,
  uintCV, standardPrincipalCV, contractPrincipalCV,
  getAddressFromPrivateKey, TransactionVersion,
} from '@stacks/transactions';
import { StacksTestnet } from '@stacks/network';
import { generateWallet } from '@stacks/wallet-sdk';

// Resolve a hex Stacks private key from either STACKS_PRIVATE_KEY (hex) or a
// STACKS_MNEMONIC (BIP-39 seed phrase; standard Stacks derivation, account 0).
export async function resolveKey({ privateKey, mnemonic } = {}) {
  const pk = privateKey || process.env.STACKS_PRIVATE_KEY;
  if (pk) return pk;
  const phrase = mnemonic || process.env.STACKS_MNEMONIC;
  if (!phrase) return null;
  const wallet = await generateWallet({ secretKey: phrase.trim(), password: '' });
  return wallet.accounts[0].stxPrivateKey;
}

const API = process.env.STACKS_API || 'https://api.testnet.hiro.so';

// sBTC token (testnet) — contract + the SIP-010 fungible-token asset name
// (confirmed via the contract interface: fungible_tokens = [{ name: "sbtc-token" }]).
export const SBTC = {
  address: 'STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2',
  name: 'sbtc-token',
  asset: 'sbtc-token',
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Poll the Stacks API until the tx leaves the mempool. Returns the final status.
async function waitForTx(txid, { tries = 40, everyMs = 6000 } = {}) {
  for (let i = 0; i < tries; i++) {
    const r = await fetch(`${API}/extended/v1/tx/${txid}`);
    if (r.ok) {
      const tx = await r.json();
      if (tx.tx_status && tx.tx_status !== 'pending') return tx;
    }
    await sleep(everyMs);
  }
  throw new Error(`tx ${txid} did not confirm in time`);
}

/**
 * Fire legion-fees.route to settle an inference bill of `amount` sBTC base units
 * to `provider`. Returns { txid, status, fee, amount } once confirmed.
 *
 * @param {object} o
 * @param {string} o.privateKey  paying agent's Stacks private key (hex)
 * @param {bigint|number} o.amount  routed amount in sBTC base units (>= dust floor)
 * @param {string} o.provider  recipient of the 92% (gateway RECIPIENT_ADDRESS)
 * @param {string} [o.feeContract]  "ADDR.legion-fees" (from the 402 challenge)
 */
export async function routePayment({ privateKey, amount, provider, feeContract }) {
  if (!privateKey) throw new Error('STACKS_PRIVATE_KEY required to pay on-chain');
  const network = new StacksTestnet({ url: API });
  const sender = getAddressFromPrivateKey(privateKey, TransactionVersion.Testnet);
  const amt = BigInt(amount);

  // route reverts u430 if the 8% fee rounds to 0 (amount < 13 base units).
  if ((amt * 800n) / 10000n === 0n) throw new Error(`amount ${amt} below dust floor (fee rounds to 0)`);

  const [feeAddr, feeName] = (feeContract || `${SBTC.address}.legion-fees`).split('.');

  // DENY mode + one exact post-condition: the agent sends out exactly `amount` sBTC.
  const postConditions = [
    makeStandardFungiblePostCondition(
      sender,
      FungibleConditionCode.Equal,
      amt,
      createAssetInfo(SBTC.address, SBTC.name, SBTC.asset),
    ),
  ];

  const tx = await makeContractCall({
    contractAddress: feeAddr,
    contractName: feeName,
    functionName: 'route',
    functionArgs: [
      contractPrincipalCV(SBTC.address, SBTC.name), // ft <sip010>
      uintCV(amt),                                  // amount
      standardPrincipalCV(provider),                // to (provider, gets 92%)
    ],
    senderKey: privateKey,
    network,
    anchorMode: AnchorMode.Any,
    postConditionMode: PostConditionMode.Deny,
    postConditions,
  });

  const res = await broadcastTransaction(tx, network);
  if (res.error) throw new Error(`broadcast failed: ${res.error} ${res.reason ?? ''} ${JSON.stringify(res.reason_data ?? {})}`);
  const txid = res.txid;

  const final = await waitForTx(txid);
  if (final.tx_status !== 'success') throw new Error(`route tx ${txid} ended ${final.tx_status}`);

  const fee = (amt * 800n) / 10000n; // 8% that landed in the treasury
  return { txid, status: final.tx_status, amount: amt, fee, sender, provider };
}
