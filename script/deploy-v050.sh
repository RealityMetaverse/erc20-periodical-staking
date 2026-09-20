#!/usr/bin/env bash
# Deploy ERC20PeriodicalStaking v0.5.0 + LimitController with script/DeployV050.s.sol.
#
#   ./script/deploy-v050.sh <network> [--broadcast]
#
# Loads deploy/v050/<network>.env (and nothing else), checks the RPC is really that network, prints the
# non-secret settings and SIMULATES by default. Transactions are sent only with --broadcast.
#
# Secrets never reach forge's argv: PRIVATE_KEY and ETHERSCAN_API_KEY are passed as environment variables, and the
# RPC URL through the `deploy-v050` alias in foundry.toml ([rpc_endpoints] deploy-v050 = "${RPC_URL}").
set -euo pipefail

die() { echo "deploy-v050: error: $*" >&2; exit 1; }
warn() { echo "deploy-v050: WARNING: $*" >&2; }

usage() {
  echo "usage: $0 <polygon|amoy> [--broadcast | --verify-only]" >&2
  echo "  --broadcast    send the transactions (default: simulate only)" >&2
  echo "  --verify-only  send nothing; re-run the self-check against VERIFY_STAKING / VERIFY_CONTROLLER" >&2
  echo "                 as they are ON CHAIN (needs VERIFY_STAKING, VERIFY_CONTROLLER, DEPLOYER_ADDRESS" >&2
  echo "                 in the env file). This is the mandatory step after a broadcast: the self-check" >&2
  echo "                 inside a broadcast run reads the simulation's state, not what was mined." >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ $# -ge 1 ] || usage
NETWORK="$1"
shift
BROADCAST=false
VERIFY_ONLY_MODE=false
for arg in "$@"; do
  case "$arg" in
    --broadcast) BROADCAST=true ;;
    --verify-only) VERIFY_ONLY_MODE=true ;;
    -h | --help) usage ;;
    *) die "unknown argument '$arg' (only --broadcast and --verify-only are accepted; put extra forge flags in FORGE_ARGS)" ;;
  esac
done
if $BROADCAST && $VERIFY_ONLY_MODE; then
  die "--verify-only and --broadcast are mutually exclusive: verify-only only reads the chain, it never sends"
fi

case "$NETWORK" in
  polygon) EXPECTED_CHAIN_ID=137 ;;
  amoy) EXPECTED_CHAIN_ID=80002 ;;
  *) die "unknown network '$NETWORK' (expected polygon or amoy)" ;;
esac

ENV_FILE="$ROOT/deploy/v050/$NETWORK.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE
  create it with: cp deploy/v050/$NETWORK.env.example deploy/v050/$NETWORK.env   (then fill in the placeholders)"

# Variables DeployV050.s.sol reads. Every one is exported below, empty meaning "use the default"
# (the script treats an empty value as unset).
SCRIPT_VARS=(SOURCE_STAKING REQUIREMENT_CHECKER_V2 VOUCHER_SIGNER TREASURY MAX_EXTRA_APY_BPS MAX_EXTRA_LIMIT_TOTAL
  MAX_EXTRA_LIMIT_PER_CELL MAX_VOUCHER_VALIDITY
  NEW_OWNER ADMINS OPEN_STAKING REWARD_TOP_UP WALLET_LIMITS_FILE RESUME_STAKING RESUME_CONTROLLER PRIVATE_KEY
  ALLOW_SHARED_ROLES VERIFY_ONLY VERIFY_STAKING VERIFY_CONTROLLER)
# Variables forge itself reads for this run (the rpc alias in foundry.toml, --verify).
FORGE_VARS=(RPC_URL ETHERSCAN_API_KEY)
# Wrapper-only settings.
WRAPPER_VARS=(CHAIN_NAME DEPLOYER_ADDRESS DEPLOYER_ACCOUNT POLYGONSCAN_API_KEY FORGE_ARGS BACKEND_VALIDITY_SECONDS
  GAS_ESTIMATE_MULTIPLIER RPC_TIMEOUT TX_TIMEOUT VERIFY_RETRIES VERIFY_DELAY RPC_RETRIES RPC_RETRY_DELAY)

# forge (and cast) auto-load $ROOT/.env without overriding variables already set. Anything DeployV050 or forge reads
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
  forge auto-loads that file, so these could override or add to deploy/v050/$NETWORK.env for this deployment.
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
      echo "deploy-v050: RPC read failed (attempt $attempt/${RPC_RETRIES:-3}), retrying in ${RPC_RETRY_DELAY:-3}s..." >&2
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
need_uint MAX_EXTRA_LIMIT_TOTAL
need_uint MAX_EXTRA_LIMIT_PER_CELL
need_uint MAX_VOUCHER_VALIDITY
# The contract rejects 0 (it would revert every stake and reads like "disabled" when it is the opposite).
if [ "$MAX_VOUCHER_VALIDITY" = "0" ]; then
  die "MAX_VOUCHER_VALIDITY must be non-zero in $ENV_FILE: 0 would make every voucher revert. This protection
  has no off switch - lower the value instead."
fi
# Cross-repo: the backend signs vouchers with validUntil = now + validity_seconds (its model bounds it 60-1800).
# It DOES read this ceiling on chain and refuses to sign with a 503 before allocating a nonce, exactly as it
# does for the other three caps, so a ceiling below its setting fails closed rather than stranding users. This
# check is defence in depth: it turns a whole-programme outage that nobody sees until the first stake attempt
# into a deploy that stops. BACKEND_VALIDITY_SECONDS lets ops state the backend's real setting; without it the
# only value that is safe for certain is the backend's hard maximum.
BACKEND_VALIDITY_MAX=1800
if [ -n "${BACKEND_VALIDITY_SECONDS:-}" ] && [[ "$BACKEND_VALIDITY_SECONDS" != *"<"* ]]; then
  need_uint BACKEND_VALIDITY_SECONDS
  [ "$BACKEND_VALIDITY_SECONDS" -ge 60 ] && [ "$BACKEND_VALIDITY_SECONDS" -le "$BACKEND_VALIDITY_MAX" ] ||
    die "BACKEND_VALIDITY_SECONDS is $BACKEND_VALIDITY_SECONDS in $ENV_FILE, outside the 60-$BACKEND_VALIDITY_MAX range the
  backend accepts for validity_seconds: this cannot be the backend's setting. Read it from the staking voucher
  config (admin panel or StakingVoucherConfig.validity_seconds) and copy it verbatim."
  if [ "$MAX_VOUCHER_VALIDITY" -lt "$BACKEND_VALIDITY_SECONDS" ]; then
    die "MAX_VOUCHER_VALIDITY is $MAX_VOUCHER_VALIDITY but the backend signs vouchers valid for
  BACKEND_VALIDITY_SECONDS=$BACKEND_VALIDITY_SECONDS ($ENV_FILE): every voucher would revert VoucherValidityTooLong
  after the user paid for the approve. Raise MAX_VOUCHER_VALIDITY to at least $BACKEND_VALIDITY_SECONDS, or lower
  the backend's validity_seconds first and update BACKEND_VALIDITY_SECONDS."
  fi
elif [ "$MAX_VOUCHER_VALIDITY" -lt "$BACKEND_VALIDITY_MAX" ]; then
  BACKEND_VALIDITY_SECONDS=""
  warn "MAX_VOUCHER_VALIDITY is $MAX_VOUCHER_VALIDITY and BACKEND_VALIDITY_SECONDS is not set, so this check is
  WEAKER than it should be: without the backend's real validity_seconds the only value known to be safe is its
  hard maximum of $BACKEND_VALIDITY_MAX, and $MAX_VOUCHER_VALIDITY is below that. If the backend is configured above
  $MAX_VOUCHER_VALIDITY, every voucher will revert VoucherValidityTooLong after the user paid for the approve.
  Set BACKEND_VALIDITY_SECONDS in $ENV_FILE to the backend's value and the wrapper refuses instead of warning."
else
  BACKEND_VALIDITY_SECONDS=""
fi
# A zero per-cell ceiling disables the voucher bonus outright (every voucher carrying a non-zero
# extraLimitPerCell reverts). Catch it here rather than after the deploy. Set both to 0 to disable it on purpose.
if [ "$MAX_EXTRA_LIMIT_PER_CELL" = "0" ] && [ "$MAX_EXTRA_LIMIT_TOTAL" != "0" ]; then
  die "MAX_EXTRA_LIMIT_PER_CELL is 0 while MAX_EXTRA_LIMIT_TOTAL is $MAX_EXTRA_LIMIT_TOTAL in $ENV_FILE: no voucher could
  ever spend its bonus. Set a per-cell ceiling, or set MAX_EXTRA_LIMIT_TOTAL to 0 to disable the bonus deliberately."
fi
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
if [ -n "${ALLOW_SHARED_ROLES:-}" ] && [ "$ALLOW_SHARED_ROLES" != true ] && [ "$ALLOW_SHARED_ROLES" != false ]; then
  die "ALLOW_SHARED_ROLES must be true or false"
fi

# ---------------------------------------------------------------------------
# FORGE_ARGS: word-split, never glob-expanded, and never a way around this wrapper
# ---------------------------------------------------------------------------
# The split is deliberate (FORGE_ARGS="--out /tmp/out --cache-path /tmp/cache" must become two flags and two
# values), but GLOB expansion is not: `set -f` stops a value such as "--out /tmp/*/out" from becoming whatever
# happens to match on disk, and an unmatched pattern from silently travelling through verbatim.
set -f
# shellcheck disable=SC2206
EXTRA_ARGS=(${FORGE_ARGS:-})
set +f

# FORGE_ARGS must not be able to silently send transactions or override the wrapper's signer/network guards.
# This is an ALLOWLIST, deliberately: a denylist of "dangerous" flags is a losing game against a CLI that keeps
# adding them. Flags that were missed by the previous denylist and that this allowlist now rejects, as examples
# of what the list has to keep out:
#   --resume            re-submits the transactions of a cached broadcast. It SENDS while this wrapper's banner
#                       still says "simulation (no transactions)" - the worst possible failure mode.
#   --skip-simulation   sends without simulating, defeating the whole point of the default mode.
#   --private-keys / --accounts / --interactives / -i
#                       signer flags (plural / count forms) that replace the keystore or key the env file chose,
#                       so the transactions would be signed by an account this wrapper never validated and never
#                       printed in its banner.
# Also kept out, as before: --broadcast / --verify (turn a simulation into a real, irreversible deployment),
# --rpc-url / --fork-url (point forge at a chain the `cast chain-id` check below never saw - exactly the network
# mix-up that check exists to prevent), --sender / --account / --ledger / --trezor / --mnemonic* / --keystore*.
#
# Everything below is either output-only or a knob on the robustness defaults the README documents as
# overridable through FORGE_ARGS. Checked here, before the size gate and the first RPC read, so a bad value
# fails in a second rather than after a full build.
#
# Boolean flags: no value of their own.
# --silent and --json are deliberately NOT here: both suppress the resolved-settings printout that the
# pre-broadcast banner tells the operator to compare against their env file. Allowing them would turn that
# mandatory cross-check into a silent no-op.
ALLOWED_BOOL_ARGS=(--slow --isolate --legacy --force --no-cache)
# Value flags: "--flag value" or "--flag=value". The value is accepted as-is (it is never a flag itself).
ALLOWED_VALUE_ARGS=(--gas-estimate-multiplier --gas-price --priority-gas-price --gas-limit --rpc-timeout
  --timeout --retries --delay --out --cache-path --optimizer-runs --evm-version)

in_list() {
  local needle="$1" x
  shift
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

reject_forge_arg() {
  die "FORGE_ARGS in $ENV_FILE contains '$1', which is NOT on this wrapper's allowlist. $2
  FORGE_ARGS is an allowlist, not a denylist: only these may appear.
    boolean:  -v/-vv/-vvv/-vvvv/-vvvvv ${ALLOWED_BOOL_ARGS[*]}
    with a value (--flag value or --flag=value):
              ${ALLOWED_VALUE_ARGS[*]}
  To deploy, pass the --broadcast argument to this script. To choose the signer set DEPLOYER_ACCOUNT
  (+ DEPLOYER_ADDRESS) or PRIVATE_KEY, to choose the network set RPC_URL, and to turn verification on set
  ETHERSCAN_API_KEY - all in $ENV_FILE, never in FORGE_ARGS."
}

ARG_COUNT=${#EXTRA_ARGS[@]}
ai=0
while [ "$ai" -lt "$ARG_COUNT" ]; do
  a="${EXTRA_ARGS[$ai]}"
  case "$a" in
    --)
      reject_forge_arg "$a" "Everything after '--' is passed through to the script unchecked."
      ;;
    -v | -vv | -vvv | -vvvv | -vvvvv)
      ai=$((ai + 1))
      continue
      ;;
    -*) ;;
    *)
      reject_forge_arg "$a" "FORGE_ARGS takes flags only; a bare word would become a forge positional argument
  (a script path or a function signature), replacing the script this wrapper runs."
      ;;
  esac
  # --flag=value / --flag value
  name="${a%%=*}"
  if [ "$name" = "$a" ]; then has_value=false; else has_value=true; fi
  if in_list "$name" ${ALLOWED_BOOL_ARGS[@]+"${ALLOWED_BOOL_ARGS[@]}"}; then
    $has_value && die "FORGE_ARGS in $ENV_FILE contains '$a', but $name takes no value."
    ai=$((ai + 1))
  elif in_list "$name" ${ALLOWED_VALUE_ARGS[@]+"${ALLOWED_VALUE_ARGS[@]}"}; then
    if $has_value; then
      ai=$((ai + 1))
    else
      [ $((ai + 1)) -lt "$ARG_COUNT" ] || die "FORGE_ARGS in $ENV_FILE ends with '$a', which needs a value."
      # The value must not look like another flag: "--out --slow" would silently eat the next flag.
      case "${EXTRA_ARGS[$((ai + 1))]}" in
        -*) die "FORGE_ARGS in $ENV_FILE has '$a' followed by '${EXTRA_ARGS[$((ai + 1))]}', which is a flag, not a value." ;;
      esac
      ai=$((ai + 2))
    fi
  else
    reject_forge_arg "$a" "It is not one of the flags this wrapper accepts."
  fi
done
unset ARG_COUNT ai name has_value

# --verify-only: the mode is chosen on the command line, never by the env file, so a stray VERIFY_ONLY=true in
# deploy/v050/<network>.env can neither turn a deployment into a no-op nor the other way round.
if $VERIFY_ONLY_MODE; then
  for v in VERIFY_STAKING VERIFY_CONTROLLER DEPLOYER_ADDRESS; do
    is_addr "${!v:-}" || die "--verify-only needs $v in $ENV_FILE to be a 0x address (got '${!v:-<unset>}').
  VERIFY_STAKING and VERIFY_CONTROLLER are the two deployed contracts to check (see
  broadcast/DeployV050.s.sol/$EXPECTED_CHAIN_ID/run-latest.json), DEPLOYER_ADDRESS the account that broadcast
  them: the ownership check accepts either the deployer still owning with NEW_OWNER pending, or NEW_OWNER
  having already called acceptOwnership() on both contracts - but BOTH must be at the same stage, so a
  half-finished hand-off (one accepted, one forgotten) fails and names the contract still pending."
  done
  VERIFY_ONLY=true
else
  VERIFY_ONLY=""
  VERIFY_STAKING=""
  VERIFY_CONTROLLER=""
fi
if [ -n "${ADMINS:-}" ]; then
  IFS=',' read -r -a ADMIN_LIST <<<"$ADMINS"
  for a in "${ADMIN_LIST[@]}"; do
    is_addr "$a" || die "ADMINS in $ENV_FILE must be comma-separated 0x addresses without spaces (got '$a')"
  done
fi
if [ -n "${WALLET_LIMITS_FILE:-}" ]; then
  # foundry.toml only grants the script read access to deploy/v050/ (and the test fixtures).
  [[ "$WALLET_LIMITS_FILE" == deploy/v050/* && "$WALLET_LIMITS_FILE" != *..* ]] ||
    die "WALLET_LIMITS_FILE must be a relative path under deploy/v050/ (got '$WALLET_LIMITS_FILE')"
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

# Size gate. `forge script` and `forge test` do not enforce the 24,576-byte EIP-170 runtime limit, so an oversized
# contract is otherwise found out on chain, as a failed deployment. v0.5.0 was 957 bytes over for a while with
# every test green.
echo "=== contract size check (EIP-170 limit: 24576 bytes) ==="
"$FORGE" build --sizes --skip "test/**" --skip "script/**" >/dev/null 2>&1 \
  || die "a contract is over the 24,576-byte runtime limit (or src does not compile) and cannot be deployed. See: forge build --sizes --skip 'test/**' --skip 'script/**'"

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
# DEPLOYER_ADDRESS is wrapper-only in every other mode; verify-only is the one where the Solidity script reads it.
if $VERIFY_ONLY_MODE; then export DEPLOYER_ADDRESS; fi

# FORGE_ARGS wins: a flag named there is not added again (forge would see it twice).
forge_args_has() {
  local a
  for a in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    [ "${a%%=*}" = "$1" ] && return 0
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
echo "=== deploy-v050: $NETWORK ==="
show "env file" "${ENV_FILE#"$ROOT"/}"
show "chain id" "$CHAIN_ID"
show "rpc" "$RPC_HOST/... (alias deploy-v050)"
if $VERIFY_ONLY_MODE; then
  show "mode" "VERIFY-ONLY (no transactions; checks the contracts below as they are on chain)"
  show "VERIFY_STAKING" "$VERIFY_STAKING"
  show "VERIFY_CONTROLLER" "$VERIFY_CONTROLLER"
else
  show "mode" "$($BROADCAST && echo 'BROADCAST' || echo 'simulation (no transactions)')"
fi
show "SOURCE_STAKING" "${SOURCE_STAKING:-<empty: per-chain table in DeployV050.s.sol>}"
show "REQUIREMENT_CHECKER_V2" "${REQUIREMENT_CHECKER_V2:-<empty: per-chain table in DeployV050.s.sol>}"
show "VOUCHER_SIGNER" "$VOUCHER_SIGNER"
show "TREASURY" "$TREASURY"
show "MAX_EXTRA_APY_BPS" "$MAX_EXTRA_APY_BPS"
show "MAX_EXTRA_LIMIT_TOTAL" "$MAX_EXTRA_LIMIT_TOTAL"
show "MAX_EXTRA_LIMIT_PER_CELL" "$MAX_EXTRA_LIMIT_PER_CELL"
show "MAX_VOUCHER_VALIDITY" "$MAX_VOUCHER_VALIDITY seconds"
show "BACKEND_VALIDITY_SECONDS" "${BACKEND_VALIDITY_SECONDS:-<not set: checked only against the backend hard maximum of $BACKEND_VALIDITY_MAX>}"
show "NEW_OWNER" "${NEW_OWNER:-<empty: 0x0000000000000000000000000000000000000000, deployer keeps ownership>}"
show "ADMINS" "${ADMINS:-<empty: none>}"
show "OPEN_STAKING" "${OPEN_STAKING:-false (empty: default)}"
show "REWARD_TOP_UP" "${REWARD_TOP_UP:-0 (empty: default, no funding)}"
show "WALLET_LIMITS_FILE" "${WALLET_LIMITS_FILE:-<empty: none>}"
show "RESUME_STAKING" "${RESUME_STAKING:-<empty: deploy a new staking contract>}"
show "RESUME_CONTROLLER" "${RESUME_CONTROLLER:-<empty: deploy a new LimitController>}"
show "ALLOW_SHARED_ROLES" "${ALLOW_SHARED_ROLES:-false (empty: default, a shared role FAILS the preflight)}"
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
echo "  CHECK: the script prints its resolved settings under '=== DeployV050: source (v0.2.4) ===' (source staking,"
echo "  RequirementCheckerV2, voucher signer, treasury, caps, new owner, admins, open staking, reward top-up, wallet"
echo "  limits file). They must equal the values above; if anything differs, stop and do not broadcast."
echo

CMD=("$FORGE" script script/DeployV050.s.sol --rpc-url deploy-v050 "${SIGN_ARGS[@]}" "${ROBUST_ARGS[@]}" "${EXTRA_ARGS[@]}")
if $BROADCAST; then CMD+=(--broadcast "${VERIFY_ARGS[@]}"); fi

exec "${CMD[@]}"
