#!/usr/bin/env bash
# Poll until the settlement window opens, then settle once and verify.
#
# `settle` is permissionless, so this deliberately runs as an agent that
# contributed nothing, voted on nothing, and receives nothing. If it works, the
# claim "nobody has to be online or trusted for correspondents to get paid"
# holds in practice, not just in the contract comments.
#
#   STACKS_MNEMONIC="..." ./scripts/watch-settle.sh
set -uo pipefail
cd "$(dirname "$0")/.."

WEEK=${WEEK:-2026-07-20}
A07=ST34Q5MVC410NTEK8G00G2QZ1JTBB2WJTNABTE6RA
A08=ST1QQ1NJMM3MH73X2W2DD7K9K2G9CHW00D9FVX7PD
A01=STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J  # proposer, earns NO fee in v2

sbtc() {
  curl -s --max-time 20 "https://api.testnet.hiro.so/extended/v1/address/$1/balances" |
    python3 -c "import sys,json;d=json.load(sys.stdin);f=d.get('fungible_tokens',{});k=[x for x in f if 'sbtc-token' in x];print(f[k[0]]['balance'] if k else 0)" 2>/dev/null || echo 0
}

B07=$(sbtc $A07); B08=$(sbtc $A08); B01=$(sbtc $A01)
echo "before  agent-07 $B07  agent-08 $B08  agent-01 $B01"

for i in $(seq 1 90); do
  line=$(node scripts/flow.mjs status 2>/dev/null | grep "settle at")
  echo "[$(date +%H:%M:%S)] $line"
  if echo "$line" | grep -q "(ready)"; then
    echo "=== window open, settling ==="
    node scripts/flow.mjs conclude 2>&1 | grep -vE "Deprecation|trace-deprecation"
    break
  fi
  sleep 60
done

echo "=== waiting for conclude to confirm ==="
for i in $(seq 1 20); do
  st=$(node scripts/flow.mjs status 2>/dev/null | grep "status ")
  echo "[$(date +%H:%M:%S)] $st"
  echo "$st" | grep -q OPEN || break
  sleep 40
done

A07n=$(sbtc $A07); A08n=$(sbtc $A08); A01n=$(sbtc $A01)
echo
echo "after   agent-07 $A07n  agent-08 $A08n  agent-01 $A01n"
echo "delta   agent-07 $((A07n-B07))  (expect 150000 = 30 x 5000)"
echo "        agent-08 $((A08n-B08))  (expect 100000 = 20 x 5000)"
echo "        agent-01 $((A01n-B01))  (expect 0, no proposer fee in v2)"
echo
node scripts/flow.mjs status 2>/dev/null
