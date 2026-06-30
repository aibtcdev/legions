#!/usr/bin/env bash
# Emit a Clarinet plan that REGISTERS each per-model legion in legion-registry
# (discovery directory). Registration is permissionless: owner = tx-sender, so
# all 7 register from agent-06 (the legions' owner). No admin key needed.
#
# register(kind, treasury, (optional gov), (optional fees), model, uri):
#   kind="provider", treasury/gov/fees = the suffixed contracts, model = a label
#   the gateway/landing-page match providers against, uri = human metadata.
#
# Apply: clarinet deployments apply --manifest-path guilds/Clarinet.models.toml \
#          -p deployments/register.testnet-plan.yaml
set -euo pipefail
cd "$(dirname "$0")/.."   # -> guilds/

SENDER="${SENDER:-STGX5YP51NKM69ZMP6DVB6GAJAANCG5WB3718KD9}"
REGISTRY="${REGISTRY:-STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J.legion-registry}"
NETWORK="${NETWORK:-testnet}"
OUT="${OUT:-deployments/register.${NETWORK}-plan.yaml}"

# suffix | model label (matched fuzzily to gateway provider model ids) | display name
ROWS=(
  "qwen|qwen2.5-7b|Qwen provider legion (governed)"
  "deepseek|deepseek-r1-32b|DeepSeek provider legion (governed)"
  "glm5|glm-5|GLM-5 provider legion (governed)"
  "kimi|kimi-k2|Kimi provider legion (governed)"
  "llama4|llama-3.3-70b|Llama 4 provider legion (governed)"
  "mistral|mistral-nemo|Mistral provider legion (governed)"
  "gemma4|gemma-4|Gemma 4 provider legion (governed)"
)

{
  echo "---"
  echo "id: 0"
  echo "name: Testnet - register per-model legions in legion-registry"
  echo "network: ${NETWORK}"
  echo "stacks-node: \"https://api.${NETWORK}.hiro.so\""
  echo "bitcoin-node: \"http://blockstack:blockstacksystem@bitcoind.${NETWORK}.stacks.co:18332\""
  echo "plan:"
  echo "  batches:"
  bid=0
  for row in "${ROWS[@]}"; do
    IFS='|' read -r s model uri <<< "$row"
    echo "    # register ${s}"
    echo "    - id: ${bid}"
    echo "      transactions:"
    echo "        - contract-call:"
    echo "            contract-id: ${REGISTRY}"
    echo "            expected-sender: ${SENDER}"
    echo "            method: register"
    echo "            parameters:"
    echo "              - '\"provider\"'"
    echo "              - \"'${SENDER}.legion-treasury-${s}\""
    echo "              - \"(some '${SENDER}.legion-gov-${s})\""
    echo "              - \"(some '${SENDER}.legion-fees-${s})\""
    echo "              - '\"${model}\"'"
    echo "              - '\"${uri}\"'"
    echo "            cost: 50000"
    echo "            anchor-block-only: false"
    echo "      epoch: \"3.0\""
    bid=$((bid+1))
  done
} > "$OUT"

echo "wrote $OUT  (${#ROWS[@]} register calls from $SENDER -> $REGISTRY)"
