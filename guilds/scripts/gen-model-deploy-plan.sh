#!/usr/bin/env bash
# Emit a Clarinet deployment plan that publishes + wires all per-model legions
# (treasury + fees + gov) from a SINGLE wallet. The plan is fully self-contained:
# each model gets a publish batch (treasury first — fees/gov reference it) followed
# by a wiring batch (set-token so deposits work, set-gov so gov can move funds).
#
# Apply with:
#   clarinet deployments apply \
#     --manifest-path guilds/Clarinet.models.toml \
#     -p guilds/deployments/models.testnet-plan.yaml
#
# Mainnet flip: override SENDER + SBTC_TOKEN (and regenerate the contracts with
# the mainnet trait/token first). Defaults target testnet under agent-06.
set -euo pipefail
cd "$(dirname "$0")/.."   # -> guilds/

SENDER="${SENDER:-STGX5YP51NKM69ZMP6DVB6GAJAANCG5WB3718KD9}"
SBTC_TOKEN="${SBTC_TOKEN:-STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token}"
NETWORK="${NETWORK:-testnet}"
OUT="${OUT:-deployments/models.${NETWORK}-plan.yaml}"
SUFFIXES=(qwen deepseek glm5 kimi llama4 mistral gemma4)

# publish-fee (microSTX) per role; gov is large so it gets more headroom.
FEE_TREASURY=400000
FEE_FEES=350000
FEE_GOV=1200000
FEE_WIRE=20000

{
  echo "---"
  echo "id: 0"
  echo "name: Testnet deployment - per-model legions (treasury+fees+gov), one wallet"
  echo "network: ${NETWORK}"
  echo "stacks-node: \"https://api.${NETWORK}.hiro.so\""
  echo "bitcoin-node: \"http://blockstack:blockstacksystem@bitcoind.${NETWORK}.stacks.co:18332\""
  echo "plan:"
  echo "  batches:"

  bid=0
  for s in "${SUFFIXES[@]}"; do
    # ---- publish batch: treasury MUST precede fees + gov (they reference it) ----
    echo "    # ${s}: publish bundle (treasury -> fees -> gov)"
    echo "    - id: ${bid}"
    echo "      transactions:"
    for role in treasury fees gov; do
      case "$role" in
        treasury) fee=$FEE_TREASURY ;;
        fees)     fee=$FEE_FEES ;;
        gov)      fee=$FEE_GOV ;;
      esac
      echo "        - contract-publish:"
      echo "            contract-name: legion-${role}-${s}"
      echo "            expected-sender: ${SENDER}"
      echo "            cost: ${fee}"
      echo "            path: contracts/models/legion-${role}-${s}.clar"
      echo "            anchor-block-only: false"
      echo "            clarity-version: 3"
    done
    echo "      epoch: \"3.0\""
    bid=$((bid+1))

    # ---- wiring batch: set-token (deposits) + set-gov (outflows) on the treasury ----
    echo "    # ${s}: wire token + gov into the treasury"
    echo "    - id: ${bid}"
    echo "      transactions:"
    echo "        - contract-call:"
    echo "            contract-id: ${SENDER}.legion-treasury-${s}"
    echo "            expected-sender: ${SENDER}"
    echo "            method: set-token"
    echo "            parameters:"
    echo "              - \"'${SBTC_TOKEN}\""
    echo "            cost: ${FEE_WIRE}"
    echo "            anchor-block-only: false"
    echo "        - contract-call:"
    echo "            contract-id: ${SENDER}.legion-treasury-${s}"
    echo "            expected-sender: ${SENDER}"
    echo "            method: set-gov"
    echo "            parameters:"
    echo "              - \"'${SENDER}.legion-gov-${s}\""
    echo "            cost: ${FEE_WIRE}"
    echo "            anchor-block-only: false"
    echo "      epoch: \"3.0\""
    bid=$((bid+1))
  done
} > "$OUT"

n=${#SUFFIXES[@]}
echo "wrote $OUT"
echo "  models: $n  | publishes: $((n*3))  | wiring calls: $((n*2))  | batches: $((n*2))"
total=$(( n*(FEE_TREASURY+FEE_FEES+FEE_GOV) + n*2*FEE_WIRE ))
echo "  sender: $SENDER"
echo "  est. total fees: ${total} microSTX (~$(awk -v t="$total" 'BEGIN{printf "%.2f", t/1000000}') STX) — fund the sender before applying"
