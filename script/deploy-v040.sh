#!/usr/bin/env bash
# Deploy ERC20PeriodicalStaking v0.4.0 + LimitController with script/DeployV040.s.sol.
#
#   ./script/deploy-v040.sh <network> [--broadcast]
#
# Loads deploy/v040/<network>.env (and nothing else), checks the RPC is really that network, prints the
# non-secret settings and SIMULATES by default. Transactions are sent only with --broadcast.
#
# Secrets never reach forge's argv: PRIVATE_KEY and ETHERSCAN_API_KEY are passed as environment variables, and the
# RPC URL through the `deploy-v040` alias in foundry.toml ([rpc_endpoints] deploy-v040 = "${RPC_URL}").
set -euo pipefail

die() { echo "deploy-v040: error: $*" >&2; exit 1; }
warn() { echo "deploy-v040: WARNING: $*" >&2; }

usage() {
  echo "usage: $0 <polygon|amoy> [--broadcast]" >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ $# -ge 1 ] || usage
NETWORK="$1"
shift
BROADCAST=false
for arg in "$@"; do
  case "$arg" in
    --broadcast) BROADCAST=true ;;
    -h | --help) usage ;;
    *) die "unknown argument '$arg' (only --broadcast is accepted; put extra forge flags in FORGE_ARGS)" ;;
  esac
done

case "$NETWORK" in
  polygon) EXPECTED_CHAIN_ID=137 ;;
  amoy) EXPECTED_CHAIN_ID=80002 ;;
  *) die "unknown network '$NETWORK' (expected polygon or amoy)" ;;
esac

ENV_FILE="$ROOT/deploy/v040/$NETWORK.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE
  create it with: cp deploy/v040/$NETWORK.env.example deploy/v040/$NETWORK.env   (then fill in the placeholders)"

# Variables DeployV040.s.sol reads. Every one is exported below, empty meaning "use the default"
# (the script treats an empty value as unset).
SCRIPT_VARS=(SOURCE_STAKING REQUIREMENT_CHECKER_V2 VOUCHER_SIGNER TREASURY MAX_EXTRA_APY_BPS MAX_EXTRA_LIMIT
  NEW_OWNER ADMINS OPEN_STAKING REWARD_TOP_UP WALLET_LIMITS_FILE RESUME_STAKING RESUME_CONTROLLER PRIVATE_KEY)
# Variables forge itself reads for this run (the rpc alias in foundry.toml, --verify).
FORGE_VARS=(RPC_URL ETHERSCAN_API_KEY)
# Wrapper-only settings.
WRAPPER_VARS=(CHAIN_NAME DEPLOYER_ADDRESS DEPLOYER_ACCOUNT POLYGONSCAN_API_KEY FORGE_ARGS
  GAS_ESTIMATE_MULTIPLIER RPC_TIMEOUT TX_TIMEOUT VERIFY_RETRIES VERIFY_DELAY RPC_RETRIES RPC_RETRY_DELAY)

# forge (and cast) auto-load $ROOT/.env without overriding variables already set. Anything DeployV040 or forge reads
# that is defined there could silently change this deployment, so refuse instead of warning.
if [ -f "$ROOT/.env" ]; then
  ROOT_ENV_NAMES="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' "$ROOT/.env" | sort -u)"
  CONFLICTS=()
  for name in $ROOT_ENV_NAMES; do
    for v in "${SCRIPT_VARS[@]}" "${FORGE_VARS[@]}"; do
      if [ "$name" = "$v" ]; then CONFLICTS+=("$name"); fi
    done
    # ETH_* (ETH_FROM, ETH_RPC_URL, ETH_KEYSTORE_ACCOUNT, ...) and FOUNDRY_* change forge's sender, RPC or config.
    case "$name" in ETH_* | FOUNDRY_*) CONFLICTS+=("$name") ;; esac
  done
  if [ ${#CONFLICTS[@]} -gt 0 ]; then
    die "$ROOT/.env defines ${CONFLICTS[*]}.
  forge auto-loads that file, so these could override or add to deploy/v040/$NETWORK.env for this deployment.
  Remove them from $ROOT/.env (or move the file away) and run again."
  fi
  warn "$ROOT/.env exists; forge auto-loads it. It defines nothing this deployment reads, so it is ignored."
fi

# Start from a clean slate: no value may come from the calling shell instead of the env file.
unset "${SCRIPT_VARS[@]}" "${FORGE_VARS[@]}" "${WRAPPER_VARS[@]}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

FORGE="${FORGE:-$(command -v forge || echo "$HOME/.foundry/bin/forge")}"
CAST="${CAST:-$(command -v cast || echo "$HOME/.foundry/bin/cast")}"
[ -x "$FORGE" ] || die "forge not found (install Foundry or set FORGE)"
[ -x "$CAST" ] || die "cast not found (install Foundry or set CAST)"

is_addr() { [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
need_addr() { is_addr "${!1:-}" || die "$1 in $ENV_FILE must be a 0x address (got '${!1:-<unset>}')"; }
need_uint() { is_uint "${!1:-}" || die "$1 in $ENV_FILE must be a decimal integer (got '${!1:-<unset>}')"; }

# The RPC URL may carry a provider key, so nothing captured from cast is ever printed unredacted.
# Stops at whitespace, quotes and the closing paren cast wraps URLs in, so only the URL is replaced.
redact_url() { sed -E 's#https?://[^ ")]*#<rpc-url>#g'; }

# rpc_read <cast args...> - retries transport failures and keeps cast's stderr (redacted) in RPC_ERR,
# so a flaky endpoint is never reported as a configuration mistake.
rpc_read() {
  local attempt out rc errfile
  errfile="$(mktemp)"
  RPC_OUT=""; RPC_ERR=""; RPC_ATTEMPTS=0
  for attempt in $(seq 1 "${RPC_RETRIES:-3}"); do
    RPC_ATTEMPTS="$attempt"
    set +e
    out="$(ETH_RPC_URL="$RPC_URL" "$CAST" "$@" 2>"$errfile")"
    rc=$?
    set -e
    if [ $rc -eq 0 ]; then
      RPC_OUT="$out"
      rm -f "$errfile"
      return 0
    fi
    if [ "$attempt" -lt "${RPC_RETRIES:-3}" ]; then
      echo "deploy-v040: RPC read failed (attempt $attempt/${RPC_RETRIES:-3}), retrying in ${RPC_RETRY_DELAY:-3}s..." >&2
      sleep "${RPC_RETRY_DELAY:-3}"
    fi
  done
  RPC_ERR="$(redact_url <"$errfile")"
  rm -f "$errfile"
  return 1
}

[ -n "${RPC_URL:-}" ] && [[ "$RPC_URL" != *"<"* ]] || die "RPC_URL is not set in $ENV_FILE"
if [ -n "${CHAIN_NAME:-}" ] && [ "$CHAIN_NAME" != "$NETWORK" ]; then
  die "CHAIN_NAME=$CHAIN_NAME in $ENV_FILE does not match the network argument '$NETWORK'"
fi
need_addr VOUCHER_SIGNER
need_addr TREASURY
need_uint MAX_EXTRA_APY_BPS
need_uint MAX_EXTRA_LIMIT
for v in SOURCE_STAKING REQUIREMENT_CHECKER_V2 NEW_OWNER DEPLOYER_ADDRESS RESUME_STAKING RESUME_CONTROLLER; do
  if [ -n "${!v:-}" ]; then need_addr "$v"; fi
done
if [ -n "${RESUME_CONTROLLER:-}" ] && [ -z "${RESUME_STAKING:-}" ]; then
  die "RESUME_CONTROLLER is set without RESUME_STAKING: a resume always needs the staking contract address"
fi
if [ -n "${REWARD_TOP_UP:-}" ]; then need_uint REWARD_TOP_UP; fi
if [ -n "${OPEN_STAKING:-}" ] && [ "$OPEN_STAKING" != true ] && [ "$OPEN_STAKING" != false ]; then
  die "OPEN_STAKING must be true or false"
fi
if [ -n "${ADMINS:-}" ]; then
  IFS=',' read -r -a ADMIN_LIST <<<"$ADMINS"
  for a in "${ADMIN_LIST[@]}"; do
    is_addr "$a" || die "ADMINS in $ENV_FILE must be comma-separated 0x addresses without spaces (got '$a')"
  done
fi
if [ -n "${WALLET_LIMITS_FILE:-}" ]; then
  # foundry.toml only grants the script read access to deploy/v040/ (and the test fixtures).
  [[ "$WALLET_LIMITS_FILE" == deploy/v040/* && "$WALLET_LIMITS_FILE" != *..* ]] ||
    die "WALLET_LIMITS_FILE must be a relative path under deploy/v040/ (got '$WALLET_LIMITS_FILE')"
  [ -f "$ROOT/$WALLET_LIMITS_FILE" ] || die "WALLET_LIMITS_FILE $WALLET_LIMITS_FILE does not exist"
fi
if [ -n "${DEPLOYER_ACCOUNT:-}" ] && [[ "$DEPLOYER_ACCOUNT" == *"<"* ]]; then DEPLOYER_ACCOUNT=""; fi

# ---------------------------------------------------------------------------
# Broadcast robustness (see README "Why the first Amoy broadcast ran out of gas")
# ---------------------------------------------------------------------------
# forge derives every transaction's gas limit from the script simulation. addStakingPeriod re-sorts a growing
# stakingPeriodList and pushStakingPhase writes 2 storage slots per period, so both get more expensive as
# earlier transactions land: an estimate made before they land is far too low (the first Amoy broadcast gave
# pushStakingPhase 39,273 gas for a call that needs 418,529). --slow is the fix: one transaction at a time,
# each confirmed before the next is estimated and sent. The multiplier is the headroom on top.
# --isolate simulates each top-level call in its own EVM context so warm state cannot carry between calls that
# become separate transactions; on forks of both networks it did not change the estimates, and is kept as
# defence in depth. NOTE: forge 1.7.1 has no RPC-level retry flag for scripts, only the timeouts below.
GAS_ESTIMATE_MULTIPLIER="${GAS_ESTIMATE_MULTIPLIER:-200}"
RPC_TIMEOUT="${RPC_TIMEOUT:-120}"
TX_TIMEOUT="${TX_TIMEOUT:-600}"
VERIFY_RETRIES="${VERIFY_RETRIES:-10}"
VERIFY_DELAY="${VERIFY_DELAY:-15}"
# Retries for the wrapper's own chain reads (not forge's broadcast, which has --slow and its own timeouts).
RPC_RETRIES="${RPC_RETRIES:-3}"
RPC_RETRY_DELAY="${RPC_RETRY_DELAY:-3}"
for v in GAS_ESTIMATE_MULTIPLIER RPC_TIMEOUT TX_TIMEOUT VERIFY_RETRIES VERIFY_DELAY RPC_RETRIES RPC_RETRY_DELAY; do
  need_uint "$v"
done
[ "$RPC_RETRIES" -ge 1 ] || die "RPC_RETRIES must be at least 1 (got $RPC_RETRIES)"
[ "$GAS_ESTIMATE_MULTIPLIER" -ge 100 ] ||
  die "GAS_ESTIMATE_MULTIPLIER must be at least 100 (100 = the bare estimate, no headroom); got $GAS_ESTIMATE_MULTIPLIER"

cd "$ROOT"

# The RPC must be the network the env file is for. ETH_RPC_URL keeps the URL out of cast's argv.
rpc_read chain-id ||
  die "RPC read failed: could not read the chain id from RPC_URL.
  Tried $RPC_ATTEMPTS time(s) before giving up. This is a network or endpoint problem, not necessarily a bad
  setting: a free-tier endpoint that rate-limits or times out looks exactly like this. Retry, raise
  RPC_RETRIES/RPC_RETRY_DELAY, or use a different RPC_URL.
  cast said (URLs redacted):
$RPC_ERR"
CHAIN_ID="$RPC_OUT"
is_uint "$CHAIN_ID" || die "RPC_URL did not return a numeric chain id (got '$CHAIN_ID')"
[ "$CHAIN_ID" = "$EXPECTED_CHAIN_ID" ] ||
  die "RPC_URL is chain $CHAIN_ID but '$NETWORK' is chain $EXPECTED_CHAIN_ID: refusing to mix networks"

# Signing. Keystore account preferred; a raw key is accepted, never printed and never put in argv.
SIGN_ARGS=()
SIGNER_DESC="forge default sender (simulation only)"
if [ -n "${DEPLOYER_ACCOUNT:-}" ]; then
  need_addr DEPLOYER_ADDRESS
  if [ -n "${PRIVATE_KEY:-}" ]; then warn "both DEPLOYER_ACCOUNT and PRIVATE_KEY set: using the keystore, ignoring PRIVATE_KEY"; fi
  PRIVATE_KEY=""
  SIGN_ARGS=(--account "$DEPLOYER_ACCOUNT" --sender "$DEPLOYER_ADDRESS")
  SIGNER_DESC="keystore account '$DEPLOYER_ACCOUNT'"
elif [ -n "${PRIVATE_KEY:-}" ]; then
  [[ "$PRIVATE_KEY" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] || die "PRIVATE_KEY in $ENV_FILE is not a 32-byte hex key (value not shown)"
  [[ "$PRIVATE_KEY" == 0x* ]] || PRIVATE_KEY="0x$PRIVATE_KEY"
  SIGNER_DESC="PRIVATE_KEY from the env file, via the environment (not shown; prefer DEPLOYER_ACCOUNT)"
  if $BROADCAST; then warn "signing with a raw PRIVATE_KEY; a Foundry keystore (DEPLOYER_ACCOUNT) is safer"; fi
  if [ -n "${DEPLOYER_ADDRESS:-}" ]; then SIGN_ARGS=(--sender "$DEPLOYER_ADDRESS"); fi
elif [ -n "${DEPLOYER_ADDRESS:-}" ]; then
  SIGN_ARGS=(--sender "$DEPLOYER_ADDRESS")
  SIGNER_DESC="--sender $DEPLOYER_ADDRESS (simulation only)"
fi
if $BROADCAST && [ -z "${DEPLOYER_ACCOUNT:-}" ] && [ -z "${PRIVATE_KEY:-}" ]; then
  die "--broadcast needs DEPLOYER_ACCOUNT (+ DEPLOYER_ADDRESS) or PRIVATE_KEY in $ENV_FILE"
fi
if ! $BROADCAST && [ -z "${DEPLOYER_ADDRESS:-}" ] && [ -z "${PRIVATE_KEY:-}" ]; then
  warn "DEPLOYER_ADDRESS not set: simulating from forge's default sender"
fi

# Verification key travels as ETHERSCAN_API_KEY (forge reads it from the environment), never as a flag.
VERIFY_ARGS=()
VERIFY_KEY="${ETHERSCAN_API_KEY:-${POLYGONSCAN_API_KEY:-}}"
ETHERSCAN_API_KEY=""
if $BROADCAST && [ -n "$VERIFY_KEY" ]; then
  VERIFY_ARGS=(--verify)
  ETHERSCAN_API_KEY="$VERIFY_KEY"
fi
unset POLYGONSCAN_API_KEY VERIFY_KEY

# Export everything forge and the script read, empty included, so nothing can be filled from elsewhere.
for v in "${SCRIPT_VARS[@]}" "${FORGE_VARS[@]}"; do
  export "$v=${!v:-}"
done

# shellcheck disable=SC2206
EXTRA_ARGS=(${FORGE_ARGS:-})

# FORGE_ARGS wins: a flag named there is not added again (forge would see it twice).
forge_args_has() {
  local a
  for a in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    [ "$a" = "$1" ] && return 0
  done
  return 1
}
ROBUST_ARGS=()
add_flag() { forge_args_has "$1" || ROBUST_ARGS+=("$@"); }
# Per-transaction EVM context, so the simulated gas includes the cold-storage costs the chain will charge.
add_flag --isolate
# One transaction at a time, each confirmed before the next is estimated and sent.
add_flag --slow
add_flag --gas-estimate-multiplier "$GAS_ESTIMATE_MULTIPLIER"
# Flaky public endpoints: a slow eth_call must not abort the run.
add_flag --rpc-timeout "$RPC_TIMEOUT"
if $BROADCAST; then
  # How long forge waits for a receipt before giving up on a sent transaction.
  add_flag --timeout "$TX_TIMEOUT"
fi
if [ ${#VERIFY_ARGS[@]} -gt 0 ]; then
  # NOTE: in forge 1.7.1 --retries/--delay are VERIFICATION retries only; they do not retry RPC calls.
  add_flag --retries "$VERIFY_RETRIES"
  add_flag --delay "$VERIFY_DELAY"
fi

RPC_HOST="$(printf '%s' "$RPC_URL" | sed -E 's#^([a-z]+://[^/?]+).*#\1#')"
show() { printf '  %-24s %s\n' "$1" "$2"; }
echo "=== deploy-v040: $NETWORK ==="
show "env file" "${ENV_FILE#"$ROOT"/}"
show "chain id" "$CHAIN_ID"
show "rpc" "$RPC_HOST/... (alias deploy-v040)"
show "mode" "$($BROADCAST && echo 'BROADCAST' || echo 'simulation (no transactions)')"
show "SOURCE_STAKING" "${SOURCE_STAKING:-<empty: per-chain table in DeployV040.s.sol>}"
show "REQUIREMENT_CHECKER_V2" "${REQUIREMENT_CHECKER_V2:-<empty: per-chain table in DeployV040.s.sol>}"
show "VOUCHER_SIGNER" "$VOUCHER_SIGNER"
show "TREASURY" "$TREASURY"
show "MAX_EXTRA_APY_BPS" "$MAX_EXTRA_APY_BPS"
show "MAX_EXTRA_LIMIT" "$MAX_EXTRA_LIMIT"
show "NEW_OWNER" "${NEW_OWNER:-<empty: 0x0000000000000000000000000000000000000000, deployer keeps ownership>}"
show "ADMINS" "${ADMINS:-<empty: none>}"
show "OPEN_STAKING" "${OPEN_STAKING:-false (empty: default)}"
show "REWARD_TOP_UP" "${REWARD_TOP_UP:-0 (empty: default, no funding)}"
show "WALLET_LIMITS_FILE" "${WALLET_LIMITS_FILE:-<empty: none>}"
show "RESUME_STAKING" "${RESUME_STAKING:-<empty: deploy a new staking contract>}"
show "RESUME_CONTROLLER" "${RESUME_CONTROLLER:-<empty: deploy a new LimitController>}"
show "DEPLOYER_ADDRESS" "${DEPLOYER_ADDRESS:-<empty>}"
show "signer" "$SIGNER_DESC"
show "verify" "$([ ${#VERIFY_ARGS[@]} -gt 0 ] && echo yes || echo no)"
echo "  --- broadcast robustness ---"
show "gas estimates" "--isolate (per-tx EVM context: cold SSTORE/SLOAD costs are counted)"
show "gas headroom" "${GAS_ESTIMATE_MULTIPLIER}% of the estimate (GAS_ESTIMATE_MULTIPLIER)"
show "tx pacing" "--slow (send one, wait for its receipt, then estimate the next)"
show "rpc timeout" "${RPC_TIMEOUT}s per request (RPC_TIMEOUT)"
show "receipt timeout" "$($BROADCAST && echo "${TX_TIMEOUT}s (TX_TIMEOUT)" || echo 'n/a (simulation)')"
show "verify retries" "$([ ${#VERIFY_ARGS[@]} -gt 0 ] && echo "$VERIFY_RETRIES every ${VERIFY_DELAY}s (VERIFY_RETRIES/VERIFY_DELAY)" || echo 'n/a (not verifying)')"
show "forge flags" "${ROBUST_ARGS[*]} ${EXTRA_ARGS[*]+${EXTRA_ARGS[*]}}"
echo "  CHECK: the script prints its resolved settings under '=== DeployV040: source (v0.2.4) ===' (source staking,"
echo "  RequirementCheckerV2, voucher signer, treasury, caps, new owner, admins, open staking, reward top-up, wallet"
echo "  limits file). They must equal the values above; if anything differs, stop and do not broadcast."
echo

CMD=("$FORGE" script script/DeployV040.s.sol --rpc-url deploy-v040 "${SIGN_ARGS[@]}" "${ROBUST_ARGS[@]}" "${EXTRA_ARGS[@]}")
if $BROADCAST; then CMD+=(--broadcast "${VERIFY_ARGS[@]}"); fi

exec "${CMD[@]}"
