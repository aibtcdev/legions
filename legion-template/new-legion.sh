#!/usr/bin/env bash
# new-legion.sh — deploy your OWN Legion from the shared template, in one command.
#
# A Legion is a governed mini-DAO: an isolated sBTC treasury + stake-weighted
# governance + an 8% fee-skim collector, all owned by YOUR wallet. This kit is
# fully standalone — just this script, the base contracts in model-base/, and
# settings/Devnet.toml. Each run stamps out a SELF-CONTAINED Clarinet project
# under legions/<name>/ (its own manifest, its own copy of the three contracts,
# and one deploy plan that publishes, wires, and registers the legion), so
# running clarinet never clobbers anything else.
#
# Why it works: the only coupling between the three contracts is the relative
# reference `.legion-treasury`. Rewriting it to `.legion-treasury-<name>` (and
# publishing the treasury under that same name) gives you a genuinely separate
# treasury + member ledger.
#
# ---------------------------------------------------------------------------
# USAGE
#   SENDER=ST..your-wallet ./new-legion.sh <name> [model] ["display name"]
#
#   <name>        lowercase [a-z0-9-], <= 24 chars — your legion's suffix.
#   model         optional capability label (default: <name>).
#   display name  optional human label for the registry entry.
#
# ENV (all optional except SENDER, which is needed to emit the deploy plan):
#   SENDER        your deploying wallet principal.
#   KIND          registry kind: "demand" | "provider" (default: demand).
#   NETWORK       testnet | mainnet (default: testnet).
#   SBTC_TOKEN    sBTC SIP-010 token   (default: testnet sBTC).
#   SIP010_TRAIT  SIP-010 trait        (default: testnet faktory trait).
#   REGISTRY      legion-registry id   (default: testnet registry).
#   LEGION_URI    off-chain metadata URI (default: "").
#
# THEN (the script prints these with your values filled in):
#   cd legions/<name>
#   clarinet check
#   clarinet deployments apply -p deployments/legion-<name>.<network>-plan.yaml
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"   # -> the standalone kit root (self-contained)

NAME="${1:-}"
MODEL="${2:-${NAME}}"
DISPLAY="${3:-Legion ${NAME}}"

# ---- validate name (must be a legal Clarity contract-name suffix) ----
if [[ -z "$NAME" ]]; then
  echo "error: legion name required." >&2
  echo "usage: SENDER=ST.. ./scripts/new-legion.sh <name> [model] [\"display name\"]" >&2
  exit 2
fi
if [[ ! "$NAME" =~ ^[a-z0-9-]+$ ]]; then
  echo "error: name '$NAME' must be lowercase [a-z0-9-] only." >&2
  exit 2
fi
if (( ${#NAME} > 24 )); then
  echo "error: name '$NAME' is ${#NAME} chars; max 24 (contract names cap at 40)." >&2
  exit 2
fi

SRC="model-base"               # generic base contracts (treasury/fees/gov)
PROJECT="legions/${NAME}"       # self-contained output project
ROLES=(treasury fees gov)

if [[ -e "$PROJECT" ]]; then
  echo "error: $PROJECT already exists — pick a different name or remove it first." >&2
  exit 3
fi

# ---- network-specific principals (testnet defaults; override for mainnet) ----
BASE_TRAIT="STTWD9SPRQVD3P733V89SV0P8RZRZNQADG034F0A.faktory-trait-v1.sip-010-trait"
BASE_TOKEN="STV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RJ5XDY2.sbtc-token"

NETWORK="${NETWORK:-testnet}"
SIP010_TRAIT="${SIP010_TRAIT:-$BASE_TRAIT}"
SBTC_TOKEN="${SBTC_TOKEN:-$BASE_TOKEN}"
REGISTRY="${REGISTRY:-STXGASYJR80W8RWNM7R4ENRJAPR75Y5W57J57V0J.legion-registry}"
KIND="${KIND:-demand}"
LEGION_URI="${LEGION_URI:-}"

# bare contract id (no trait suffix) for the manifest requirement pull.
TRAIT_CONTRACT="${SIP010_TRAIT%.*}"
# Capitalize network for the settings filename (bash 3.2-safe; no ${x^}).
NET_CAP="$(printf '%s' "${NETWORK:0:1}" | tr '[:lower:]' '[:upper:]')${NETWORK:1}"

mkdir -p "$PROJECT/contracts" "$PROJECT/deployments" "$PROJECT/settings"

# ---- 1. stamp the three contracts into the project -------------------------
for role in "${ROLES[@]}"; do
  sed \
    -e "s|\.legion-treasury|.legion-treasury-$NAME|g" \
    -e "s|$BASE_TRAIT|$SIP010_TRAIT|g" \
    -e "s|$BASE_TOKEN|$SBTC_TOKEN|g" \
    "$SRC/legion-$role.clar" > "$PROJECT/contracts/legion-$role-$NAME.clar"
done

# ---- 2. self-contained manifest --------------------------------------------
{
  echo "[project]"
  echo "name = 'legion-${NAME}'"
  echo "telemetry = false"
  echo "cache_dir = './.cache'"
  echo
  echo "[[project.requirements]]"
  echo "contract_id = '${SBTC_TOKEN}'"
  echo "[[project.requirements]]"
  echo "contract_id = '${TRAIT_CONTRACT}'"
  echo
  for role in "${ROLES[@]}"; do
    echo "[contracts.legion-${role}-${NAME}]"
    echo "path = 'contracts/legion-${role}-${NAME}.clar'"
    echo "clarity_version = 3"
    echo "epoch = 3.0"
  done
  echo
  echo "[repl.analysis]"
  echo "passes = ['check_checker']"
  echo "[repl.analysis.check_checker]"
  echo "strict = false"
  echo "trusted_sender = false"
  echo "trusted_caller = false"
  echo "callee_filter = false"
} > "$PROJECT/Clarinet.toml"

# ---- devnet settings so `clarinet check` runs out of the box ---------------
# The canonical clarinet devnet accounts (public, well-known mnemonic). `clarinet
# check` loads simnet from settings/Devnet.toml; without it the check errors.
if [[ -f settings/Devnet.toml ]]; then
  cp settings/Devnet.toml "$PROJECT/settings/Devnet.toml"
fi

# ---- keep secrets + caches out of git --------------------------------------
# Devnet.toml is the public test mnemonic (safe); the real Testnet/Mainnet
# secrets you add are ignored.
{
  echo "settings/Testnet.toml"
  echo "settings/Mainnet.toml"
  echo ".cache/"
  echo "history.txt"
} > "$PROJECT/.gitignore"

echo "Generated legion '$NAME' -> $PROJECT/"
echo "  contracts: legion-{treasury,fees,gov}-$NAME"
echo "  trait: $SIP010_TRAIT"
echo "  token: $SBTC_TOKEN"

# ---- deploy plan + settings need your wallet -------------------------------
if [[ -z "${SENDER:-}" ]]; then
  echo
  echo "note: SENDER not set — contracts + manifest written, deploy plan skipped."
  echo "      re-run with SENDER=ST..your-wallet to emit the deploy plan too,"
  echo "      or just run 'cd $PROJECT && clarinet check' to verify it compiles."
  exit 0
fi

# publish fees (microSTX); gov is the large contract.
FEE_TREASURY=400000
FEE_FEES=350000
FEE_GOV=1200000
FEE_WIRE=20000
FEE_REGISTER=50000

PLAN_REL="deployments/legion-${NAME}.${NETWORK}-plan.yaml"
PLAN_OUT="$PROJECT/$PLAN_REL"

# ---- 3. one plan: publish (treasury->fees->gov) -> wire -> register ---------
{
  echo "---"
  echo "id: 0"
  echo "name: \"Launch legion ${NAME} (publish + wire + register), one wallet\""
  echo "network: ${NETWORK}"
  echo "stacks-node: \"https://api.${NETWORK}.hiro.so\""
  echo "bitcoin-node: \"http://blockstack:blockstacksystem@bitcoind.${NETWORK}.stacks.co:18332\""
  echo "plan:"
  echo "  batches:"

  echo "    # 1/3 publish bundle (treasury MUST precede fees + gov — they reference it)"
  echo "    - id: 0"
  echo "      transactions:"
  for role in "${ROLES[@]}"; do
    case "$role" in
      treasury) fee=$FEE_TREASURY ;;
      fees)     fee=$FEE_FEES ;;
      gov)      fee=$FEE_GOV ;;
    esac
    echo "        - contract-publish:"
    echo "            contract-name: legion-${role}-${NAME}"
    echo "            expected-sender: ${SENDER}"
    echo "            cost: ${fee}"
    echo "            path: contracts/legion-${role}-${NAME}.clar"
    echo "            anchor-block-only: false"
    echo "            clarity-version: 3"
  done
  echo "      epoch: \"3.0\""

  echo "    # 2/3 wire token (enables deposits) + gov (authorizes fund moves)"
  echo "    - id: 1"
  echo "      transactions:"
  echo "        - contract-call:"
  echo "            contract-id: ${SENDER}.legion-treasury-${NAME}"
  echo "            expected-sender: ${SENDER}"
  echo "            method: set-token"
  echo "            parameters:"
  echo "              - \"'${SBTC_TOKEN}\""
  echo "            cost: ${FEE_WIRE}"
  echo "            anchor-block-only: false"
  echo "        - contract-call:"
  echo "            contract-id: ${SENDER}.legion-treasury-${NAME}"
  echo "            expected-sender: ${SENDER}"
  echo "            method: set-gov"
  echo "            parameters:"
  echo "              - \"'${SENDER}.legion-gov-${NAME}\""
  echo "            cost: ${FEE_WIRE}"
  echo "            anchor-block-only: false"
  echo "      epoch: \"3.0\""

  echo "    # 3/3 register in the shared discovery directory (permissionless; owner = sender)"
  echo "    - id: 2"
  echo "      transactions:"
  echo "        - contract-call:"
  echo "            contract-id: ${REGISTRY}"
  echo "            expected-sender: ${SENDER}"
  echo "            method: register"
  echo "            parameters:"
  echo "              - '\"${KIND}\"'"
  echo "              - \"'${SENDER}.legion-treasury-${NAME}\""
  echo "              - \"(some '${SENDER}.legion-gov-${NAME})\""
  echo "              - \"(some '${SENDER}.legion-fees-${NAME})\""
  echo "              - '\"${MODEL}\"'"
  echo "              - '\"${DISPLAY}\"'"
  echo "            cost: ${FEE_REGISTER}"
  echo "            anchor-block-only: false"
  echo "      epoch: \"3.0\""
} > "$PLAN_OUT"

# ---- 4. settings stub for the deploying wallet (mnemonic placeholder) -------
{
  echo "# Secrets for '$NAME' on ${NETWORK}. FILL IN your mnemonic; do NOT commit."
  echo "# (this file is gitignored by the project's .gitignore)"
  echo "[network]"
  echo "name = \"${NETWORK}\""
  echo
  echo "[accounts.deployer]"
  echo "mnemonic = \"<PUT YOUR 24-WORD SEED PHRASE FOR ${SENDER} HERE>\""
} > "$PROJECT/settings/${NET_CAP}.toml"

total=$(( FEE_TREASURY + FEE_FEES + FEE_GOV + 2*FEE_WIRE + FEE_REGISTER ))
echo "  plan:     $PLAN_REL"
echo "  settings: settings/${NET_CAP}.toml  (add your mnemonic — gitignored)"
echo "  owner/sender: $SENDER"
echo "  est. total fees: ${total} microSTX (~$(awk -v t="$total" 'BEGIN{printf "%.2f", t/1000000}') STX) — fund $SENDER first"
echo
echo "next — three lines:"
echo "  cd $PROJECT"
echo "  clarinet check"
echo "  clarinet deployments apply -p $PLAN_REL      # publish + wire + register"
