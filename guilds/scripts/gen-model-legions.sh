#!/usr/bin/env bash
# Generate per-model legion bundles from the base contracts, one independent set
# per model, all deployable from a SINGLE wallet by suffixing the contract names.
#
# Each model legion is a governed mini-DAO: members `stake` in legion-gov to get
# voting + proposal rights AND a ranking signal, and the 8% fee skim pools into
# that model's own legion-treasury. ROLES default to treasury+fees+gov.
#
# Why this works: the only coupling between the contracts is the RELATIVE
# reference `.legion-treasury`. Rewriting it to `.legion-treasury-<suffix>` (and
# publishing the treasury under that same name) gives each model a genuinely
# separate treasury + member ledger — no extra wallets needed.
#
# Post-deploy wiring per model (one each, deployer only):
#   legion-treasury-<s>.set-token(<sbtc>)   -> enables deposits (fee skim)
#   legion-treasury-<s>.set-gov(<gov-<s>>)  -> authorizes gov to move funds
#
# Mainnet flip: the only network-specific values are the SIP-010 trait and the
# sBTC token. Override them via env to retarget every generated contract:
#   SIP010_TRAIT=SP....sip-010-trait SBTC_TOKEN=SP....sbtc-token ./gen-model-legions.sh
#
# Output: guilds/contracts/models/legion-<role>-<suffix>.clar
set -euo pipefail
cd "$(dirname "$0")/.."   # -> guilds/

SRC="contracts/model-base"   # generic model-legion bases (treasury/fees/generic gov)
OUT="contracts/models"
SUFFIXES=(qwen deepseek glm5 kimi llama4 mistral gemma4)
# Roles per bundle. Override e.g. ROLES="treasury fees gov engage" to add the
# provider-ranking stake ledger alongside governance.
read -r -a ROLES <<< "${ROLES:-treasury fees gov}"

# The base (testnet) absolute principals as they appear in the source files.
BASE_TRAIT="STTWD9SPRQVD3P733V89SV0P8RZRZNQADG034F0A.faktory-trait-v1.sip-010-trait"
BASE_TOKEN="STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token"

# Targets (default = testnet; override for mainnet).
SIP010_TRAIT="${SIP010_TRAIT:-$BASE_TRAIT}"
SBTC_TOKEN="${SBTC_TOKEN:-$BASE_TOKEN}"

rm -rf "$OUT"
mkdir -p "$OUT"

for s in "${SUFFIXES[@]}"; do
  for role in "${ROLES[@]}"; do
    in="$SRC/legion-$role.clar"
    out="$OUT/legion-$role-$s.clar"
    sed \
      -e "s|\.legion-treasury|.legion-treasury-$s|g" \
      -e "s|$BASE_TRAIT|$SIP010_TRAIT|g" \
      -e "s|$BASE_TOKEN|$SBTC_TOKEN|g" \
      "$in" > "$out"
  done
done

echo "Generated ${#SUFFIXES[@]} model bundles (${ROLES[*]}) into $OUT/"
echo "  trait: $SIP010_TRAIT"
echo "  token: $SBTC_TOKEN"
ls -1 "$OUT" | sed 's/^/  - /'
