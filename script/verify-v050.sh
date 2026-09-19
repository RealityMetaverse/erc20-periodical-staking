#!/usr/bin/env bash
# Verify an already-deployed ERC20PeriodicalStaking v0.5.0 + LimitController pair on the block explorer.
#
#   ./script/verify-v050.sh <network> [--guid <submission-guid>]
#
# Same flow as deploy-v050.sh: loads deploy/v050/<network>.env (and nothing else), refuses to run while a root
# .env could override it, rejects placeholders and checks the RPC really is that network. Sends no transactions.
#
# script/deploy-v050.sh already verifies on --broadcast when a key is set; this script is for a deployment that
# was broadcast without one (or whose verification failed afterwards).
#
# Secrets never reach forge's argv: the API key is passed as ETHERSCAN_API_KEY in the environment and the RPC
# URL to cast as ETH_RPC_URL.
set -euo pipefail

die() { echo "verify-v050: error: $*" >&2; exit 1; }
warn() { echo "verify-v050: WARNING: $*" >&2; }

usage() {
  echo "usage: $0 <polygon|amoy> [--guid <submission-guid>]" >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ $# -ge 1 ] || usage
NETWORK="$1"
shift
GUID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --guid)
      shift
      [ $# -ge 1 ] || die "--guid needs a value"
      GUID="$1"
      ;;
    --guid=*) GUID="${1#--guid=}" ;;
    -h | --help) usage ;;
    *) die "unknown argument '$1' (only --guid <guid> is accepted)" ;;
  esac
  shift
done

case "$NETWORK" in
  polygon) EXPECTED_CHAIN_ID=137 ;;
  amoy) EXPECTED_CHAIN_ID=80002 ;;
  *) die "unknown network '$NETWORK' (expected polygon or amoy)" ;;
esac

ENV_FILE="$ROOT/deploy/v050/$NETWORK.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE
  create it with: cp deploy/v050/$NETWORK.env.example deploy/v050/$NETWORK.env   (then fill in the placeholders)"

# Everything this run reads from the env file.
VERIFY_VARS=(VERIFY_STAKING VERIFY_CONTROLLER VERIFY_RETRIES VERIFY_DELAY RPC_RETRIES RPC_RETRY_DELAY
  MAX_EXTRA_LIMIT_TOTAL MAX_EXTRA_LIMIT_PER_CELL MAX_VOUCHER_VALIDITY BACKEND_VALIDITY_SECONDS)
FORGE_VARS=(RPC_URL ETHERSCAN_API_KEY)
WRAPPER_VARS=(CHAIN_NAME POLYGONSCAN_API_KEY)

# forge and cast auto-load $ROOT/.env without overriding variables already set, so a value defined there could
# silently change which contract gets verified with which key. Refuse, exactly as deploy-v050.sh does.
if [ -f "$ROOT/.env" ]; then
  ROOT_ENV_NAMES="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' "$ROOT/.env" | sort -u)"
  CONFLICTS=()
  for name in $ROOT_ENV_NAMES; do
    for v in "${VERIFY_VARS[@]}" "${FORGE_VARS[@]}"; do
      if [ "$name" = "$v" ]; then CONFLICTS+=("$name"); fi
    done
    case "$name" in ETH_* | FOUNDRY_*) CONFLICTS+=("$name") ;; esac
  done
  if [ ${#CONFLICTS[@]} -gt 0 ]; then
    die "$ROOT/.env defines ${CONFLICTS[*]}.
  forge auto-loads that file, so these could override or add to deploy/v050/$NETWORK.env for this run.
  Remove them from $ROOT/.env (or move the file away) and run again."
  fi
  warn "$ROOT/.env exists; forge auto-loads it. It defines nothing this run reads, so it is ignored."
fi

# No value may come from the calling shell instead of the env file.
unset "${VERIFY_VARS[@]}" "${FORGE_VARS[@]}" "${WRAPPER_VARS[@]}"

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
need_uint() { is_uint "${!1:-}" || die "$1 in $ENV_FILE must be a decimal integer (got '${!1:-<unset>}')"; }
# A placeholder like "<0x-staking>" counts as unset, the same way the deploy wrapper treats them.
unplaceholder() { case "${!1:-}" in *"<"*) printf -v "$1" '%s' "" ;; esac; }

# The RPC URL may carry a provider key, so nothing captured from cast is ever printed unredacted.
# Stops at whitespace, quotes and the closing paren cast wraps URLs in, so only the URL is replaced.
redact_url() { sed -E 's#https?://[^ ")]*#<rpc-url>#g'; }

# rpc_read <cast args...>
# Runs cast against RPC_URL, retrying transport failures. On success sets RPC_OUT and returns 0.
# On failure sets RPC_ERR to cast's (redacted) stderr and returns 1, so the caller can say "the RPC
# failed" instead of blaming the contract. A read that succeeds but returns nonsense is the caller's
# business: that is the only case in which "this is not the contract I expected" is a fair diagnosis.
rpc_read() {
  local attempt out rc errfile
  errfile="$(mktemp)"
  RPC_OUT=""; RPC_ERR=""; RPC_ATTEMPTS=0
  for attempt in $(seq 1 "$RPC_RETRIES"); do
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
    if [ "$attempt" -lt "$RPC_RETRIES" ]; then
      echo "verify-v050: RPC read failed (attempt $attempt/$RPC_RETRIES), retrying in ${RPC_RETRY_DELAY}s..." >&2
      sleep "$RPC_RETRY_DELAY"
    fi
  done
  RPC_ERR="$(redact_url <"$errfile")"
  rm -f "$errfile"
  return 1
}

# Standard wording so every transport failure reads the same way.
rpc_die() {
  die "RPC read failed: $1.
  Tried $RPC_ATTEMPTS time(s) against RPC_URL (chain $EXPECTED_CHAIN_ID) before giving up. This is a network or
  endpoint problem, NOT necessarily a wrong address. A free-tier endpoint that rate-limits or times out looks
  exactly like this; retry, raise RPC_RETRIES/RPC_RETRY_DELAY, or use a different RPC_URL.
  cast said (URLs redacted):
$RPC_ERR"
}

[ -n "${RPC_URL:-}" ] && [[ "$RPC_URL" != *"<"* ]] || die "RPC_URL is not set in $ENV_FILE"
if [ -n "${CHAIN_NAME:-}" ] && [ "$CHAIN_NAME" != "$NETWORK" ]; then
  die "CHAIN_NAME=$CHAIN_NAME in $ENV_FILE does not match the network argument '$NETWORK'"
fi
unplaceholder VERIFY_STAKING
unplaceholder VERIFY_CONTROLLER
for v in VERIFY_STAKING VERIFY_CONTROLLER; do
  if [ -n "${!v:-}" ]; then
    is_addr "${!v}" || die "$v in $ENV_FILE must be a 0x address (got '${!v}')"
  fi
done
if [ -n "${VERIFY_CONTROLLER:-}" ] && [ -z "${VERIFY_STAKING:-}" ]; then
  die "VERIFY_CONTROLLER is set without VERIFY_STAKING: the controller's constructor argument is the staking address"
fi
VERIFY_RETRIES="${VERIFY_RETRIES:-10}"
VERIFY_DELAY="${VERIFY_DELAY:-15}"
# Chain reads are cheap and are retried separately from (much slower) explorer verification attempts.
RPC_RETRIES="${RPC_RETRIES:-3}"
RPC_RETRY_DELAY="${RPC_RETRY_DELAY:-3}"
for v in VERIFY_RETRIES VERIFY_DELAY RPC_RETRIES RPC_RETRY_DELAY; do need_uint "$v"; done
[ "$RPC_RETRIES" -ge 1 ] || die "RPC_RETRIES must be at least 1 (got $RPC_RETRIES)"
# Optional: the backend's staking voucher validity_seconds (its model bounds it 60-1800). Validated here, used
# against the on-chain maxVoucherValidity below. Same rules as deploy-v050.sh.
BACKEND_VALIDITY_MAX=1800
unplaceholder BACKEND_VALIDITY_SECONDS
if [ -n "${BACKEND_VALIDITY_SECONDS:-}" ]; then
  need_uint BACKEND_VALIDITY_SECONDS
  [ "$BACKEND_VALIDITY_SECONDS" -ge 60 ] && [ "$BACKEND_VALIDITY_SECONDS" -le "$BACKEND_VALIDITY_MAX" ] ||
    die "BACKEND_VALIDITY_SECONDS is $BACKEND_VALIDITY_SECONDS in $ENV_FILE, outside the 60-$BACKEND_VALIDITY_MAX range the
  backend accepts for validity_seconds: this cannot be the backend's setting. Read it from the staking voucher
  config (admin panel or StakingVoucherConfig.validity_seconds) and copy it verbatim."
fi

cd "$ROOT"

# The RPC must be the network the env file is for; the constructor arguments are read through it.
rpc_read chain-id || rpc_die "could not read the chain id from RPC_URL"
CHAIN_ID="$RPC_OUT"
is_uint "$CHAIN_ID" || die "RPC_URL did not return a numeric chain id (got '$CHAIN_ID')"
[ "$CHAIN_ID" = "$EXPECTED_CHAIN_ID" ] ||
  die "RPC_URL is chain $CHAIN_ID but '$NETWORK' is chain $EXPECTED_CHAIN_ID: refusing to mix networks"

# The verification key. Never becomes a flag: forge reads ETHERSCAN_API_KEY from the environment.
API_KEY="${ETHERSCAN_API_KEY:-${POLYGONSCAN_API_KEY:-}}"
case "$API_KEY" in *"<"*) API_KEY="" ;; esac
if [ -z "$API_KEY" ]; then
  die "no verification key: set ETHERSCAN_API_KEY (or POLYGONSCAN_API_KEY) in $ENV_FILE.
  Uncomment the '# ETHERSCAN_API_KEY=' line in ${ENV_FILE#"$ROOT"/} and put an Etherscan v2 API key after the '='.
  This is the same key deploy-v050.sh needs to pass --verify during a broadcast."
fi
unset POLYGONSCAN_API_KEY
export ETHERSCAN_API_KEY="$API_KEY"

# ---------------------------------------------------------------------------
# --guid: ask the explorer about a submission an earlier run already made
# ---------------------------------------------------------------------------
if [ -n "$GUID" ]; then
  echo "=== verify-v050: $NETWORK - checking submission $GUID ==="
  exec "$FORGE" verify-check "$GUID" --chain "$CHAIN_ID" --verifier etherscan \
    --retries "$VERIFY_RETRIES" --delay "$VERIFY_DELAY"
fi

# ---------------------------------------------------------------------------
# Addresses: env file first, then the broadcast log of this chain
# ---------------------------------------------------------------------------
BROADCAST_FILE="$ROOT/broadcast/DeployV050.s.sol/$CHAIN_ID/run-latest.json"
ADDR_SOURCE=""
if [ -n "${VERIFY_STAKING:-}" ]; then
  ADDR_SOURCE="VERIFY_STAKING / VERIFY_CONTROLLER in ${ENV_FILE#"$ROOT"/}"
  STAKING="$VERIFY_STAKING"
  CONTROLLER="${VERIFY_CONTROLLER:-}"
elif [ -f "$BROADCAST_FILE" ]; then
  ADDR_SOURCE="${BROADCAST_FILE#"$ROOT"/}"
  read_create() {
    python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for t in d.get('transactions',[]):
    if t.get('transactionType')=='CREATE' and t.get('contractName')==sys.argv[2]:
        a=t.get('contractAddress') or ''
        print(a)
        break
" "$BROADCAST_FILE" "$1" 2>/dev/null
  }
  STAKING="$(read_create ERC20PeriodicalStaking)"
  CONTROLLER="$(read_create LimitController)"
  [ -n "$STAKING" ] || die "no ERC20PeriodicalStaking CREATE entry in ${BROADCAST_FILE#"$ROOT"/}.
  Set VERIFY_STAKING (and VERIFY_CONTROLLER) in ${ENV_FILE#"$ROOT"/} to the deployed addresses."
else
  die "cannot tell which contracts to verify: VERIFY_STAKING is not set in ${ENV_FILE#"$ROOT"/} and there is no
  ${BROADCAST_FILE#"$ROOT"/} to read the deployed addresses from.
  Add to ${ENV_FILE#"$ROOT"/}:
    VERIFY_STAKING=0x...        # the deployed ERC20PeriodicalStaking
    VERIFY_CONTROLLER=0x...     # the deployed LimitController (optional)"
fi

is_addr "$STAKING" || die "resolved staking address '$STAKING' is not a 0x address (source: $ADDR_SOURCE)"
if [ -n "${CONTROLLER:-}" ] && ! is_addr "$CONTROLLER"; then
  die "resolved controller address '$CONTROLLER' is not a 0x address (source: $ADDR_SOURCE)"
fi

# ---------------------------------------------------------------------------
# Constructor arguments are READ FROM CHAIN, never guessed
# ---------------------------------------------------------------------------
# ERC20PeriodicalStaking(address stakingToken) -> its own STAKING_TOKEN()
# LimitController(address stakingContract)     -> its own stakingContract()
rpc_read code "$STAKING" || rpc_die "could not read the code at the staking address $STAKING"
[ "$RPC_OUT" != "0x" ] ||
  die "no contract code at the staking address $STAKING on chain $CHAIN_ID (source: $ADDR_SOURCE)"

rpc_read call "$STAKING" 'STAKING_TOKEN()(address)' ||
  rpc_die "could not read STAKING_TOKEN() from the staking contract $STAKING"
TOKEN="$RPC_OUT"
is_addr "$TOKEN" ||
  die "STAKING_TOKEN() on $STAKING returned '$TOKEN', not an address: it does not look like an
  ERC20PeriodicalStaking. The read itself succeeded, so the endpoint is fine and the address is the problem."

# The voucher bonus ceilings are read back from the deployed contract, not trusted from the env file. A
# maxExtraLimitPerCell of 0 alongside a non-zero maxExtraLimitTotal means every voucher carrying a bonus reverts
# VoucherExtraLimitPerCellTooHigh: the program looks deployed but the bonus is silently off. Fail here.
rpc_read call "$STAKING" 'maxExtraLimitTotal()(uint256)' ||
  rpc_die "could not read maxExtraLimitTotal() from the staking contract $STAKING"
CHAIN_MAX_EXTRA_LIMIT_TOTAL="${RPC_OUT%% *}"
rpc_read call "$STAKING" 'maxExtraLimitPerCell()(uint256)' ||
  rpc_die "could not read maxExtraLimitPerCell() from the staking contract $STAKING"
CHAIN_MAX_EXTRA_LIMIT_PER_CELL="${RPC_OUT%% *}"
rpc_read call "$STAKING" 'maxVoucherValidity()(uint256)' ||
  rpc_die "could not read maxVoucherValidity() from the staking contract $STAKING"
CHAIN_MAX_VOUCHER_VALIDITY="${RPC_OUT%% *}"

# A v0.5.0 contract can never read 0 here: the constructor sets 1800 and setMaxVoucherValidity rejects 0. So
# this branch does not mean "someone forgot to set it" -- it means this is not the contract you think it is
# (wrong address, or an older build without the ceiling). Check VERSION() before doing anything else.
if [ "$CHAIN_MAX_VOUCHER_VALIDITY" = "0" ]; then
  die "the deployed staking contract $STAKING has maxVoucherValidity = 0: every voucher reverts
  VoucherValidityTooLong. Call setMaxVoucherValidity as the owner (MAX_VOUCHER_VALIDITY in $ENV_FILE)."
fi

# Cross-repo: the backend reads this ceiling on chain and refuses to sign (503, before allocating a nonce) when
# its own validity_seconds exceeds it, so a ceiling lowered later with setMaxVoucherValidity stops voucher
# issuance rather than stranding users mid-stake. Catching it here says WHY issuance stopped, in one line,
# instead of leaving someone to infer it from 503s. Same comparison as deploy-v050.sh, against the chain value.
if [ -n "${BACKEND_VALIDITY_SECONDS:-}" ]; then
  if [ "$CHAIN_MAX_VOUCHER_VALIDITY" -lt "$BACKEND_VALIDITY_SECONDS" ]; then
    die "the deployed staking contract $STAKING has maxVoucherValidity = $CHAIN_MAX_VOUCHER_VALIDITY but the backend
  signs vouchers valid for BACKEND_VALIDITY_SECONDS=$BACKEND_VALIDITY_SECONDS ($ENV_FILE): every voucher reverts
  VoucherValidityTooLong after the user paid for the approve. Call setMaxVoucherValidity($BACKEND_VALIDITY_SECONDS
  or more) as the owner, or lower the backend's validity_seconds first."
  fi
elif [ "$CHAIN_MAX_VOUCHER_VALIDITY" -lt "$BACKEND_VALIDITY_MAX" ]; then
  warn "the deployed staking contract $STAKING has maxVoucherValidity = $CHAIN_MAX_VOUCHER_VALIDITY and
  BACKEND_VALIDITY_SECONDS is not set, so this check is WEAKER than it should be: without the backend's real
  validity_seconds the only value known to be safe is its hard maximum of $BACKEND_VALIDITY_MAX. If the backend is
  configured above $CHAIN_MAX_VOUCHER_VALIDITY, every voucher reverts VoucherValidityTooLong after the user paid for
  the approve. Set BACKEND_VALIDITY_SECONDS in $ENV_FILE to the backend's value and this script refuses instead."
fi

if [ "$CHAIN_MAX_EXTRA_LIMIT_PER_CELL" = "0" ] && [ "$CHAIN_MAX_EXTRA_LIMIT_TOTAL" != "0" ]; then
  die "the deployed staking contract $STAKING has maxExtraLimitPerCell = 0 while maxExtraLimitTotal =
  $CHAIN_MAX_EXTRA_LIMIT_TOTAL: no voucher can spend its bonus and every stake carrying one reverts. Call
  setMaxExtraLimitPerCell as the owner (MAX_EXTRA_LIMIT_PER_CELL in $ENV_FILE) before announcing the program."
fi

for v in MAX_EXTRA_LIMIT_TOTAL MAX_EXTRA_LIMIT_PER_CELL MAX_VOUCHER_VALIDITY; do
  expected="${!v:-}"
  # An unfilled placeholder like "<token-wei>" counts as unset, as everywhere else in this script.
  case "$expected" in *"<"*) expected="" ;; esac
  if [ -n "$expected" ]; then
    eval "actual=\$CHAIN_$v"
    [ "$expected" = "$actual" ] ||
      warn "$v in $ENV_FILE is $expected but the deployed contract reports $actual"
  fi
done

if [ -n "${CONTROLLER:-}" ]; then
  rpc_read code "$CONTROLLER" || rpc_die "could not read the code at the controller address $CONTROLLER"
  [ "$RPC_OUT" != "0x" ] ||
    die "no contract code at the controller address $CONTROLLER on chain $CHAIN_ID (source: $ADDR_SOURCE)"

  rpc_read call "$CONTROLLER" 'stakingContract()(address)' ||
    rpc_die "could not read stakingContract() from the LimitController $CONTROLLER"
  CTRL_TARGET="$RPC_OUT"
  is_addr "$CTRL_TARGET" ||
    die "stakingContract() on $CONTROLLER returned '$CTRL_TARGET', not an address: it does not look like a
  LimitController. The read itself succeeded, so the endpoint is fine and the address is the problem."
  # Compare case-insensitively: cast returns EIP-55 checksummed, env files often hold lowercase.
  if [ "${CTRL_TARGET,,}" != "${STAKING,,}" ]; then
    die "the LimitController $CONTROLLER was built for $CTRL_TARGET, not for the staking contract being
  verified ($STAKING). Verifying it with the wrong constructor argument would fail; check the addresses."
  fi
fi

STAKING_ARGS="$("$CAST" abi-encode 'constructor(address)' "$TOKEN")"
[ -n "${CONTROLLER:-}" ] && CONTROLLER_ARGS="$("$CAST" abi-encode 'constructor(address)' "$STAKING")"

RPC_HOST="$(printf '%s' "$RPC_URL" | sed -E 's#^([a-z]+://[^/?]+).*#\1#')"
show() { printf '  %-24s %s\n' "$1" "$2"; }
echo "=== verify-v050: $NETWORK ==="
show "env file" "${ENV_FILE#"$ROOT"/}"
show "chain id" "$CHAIN_ID"
show "rpc" "$RPC_HOST/..."
show "addresses from" "$ADDR_SOURCE"
show "staking" "$STAKING"
show "  constructor token" "$TOKEN (read from STAKING_TOKEN())"
show "  maxExtraLimitTotal" "$CHAIN_MAX_EXTRA_LIMIT_TOTAL (read from chain)"
show "  maxExtraLimitPerCell" "$CHAIN_MAX_EXTRA_LIMIT_PER_CELL (read from chain)"
show "  maxVoucherValidity" "$CHAIN_MAX_VOUCHER_VALIDITY s (read from chain)"
show "  backend validity" "${BACKEND_VALIDITY_SECONDS:-<BACKEND_VALIDITY_SECONDS not set: checked only against the backend hard maximum of $BACKEND_VALIDITY_MAX>}"
show "controller" "${CONTROLLER:-<unknown: only the staking contract will be verified>}"
if [ -n "${CONTROLLER:-}" ]; then
  show "  constructor staking" "$CTRL_TARGET (read from stakingContract())"
fi
show "verify retries" "$VERIFY_RETRIES every ${VERIFY_DELAY}s (VERIFY_RETRIES/VERIFY_DELAY)"
show "rpc read retries" "$RPC_RETRIES every ${RPC_RETRY_DELAY}s (RPC_RETRIES/RPC_RETRY_DELAY)"
show "api key" "set (passed as ETHERSCAN_API_KEY in the environment)"
echo

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
STAKING_STATUS="not attempted"
CONTROLLER_STATUS="not deployed / unknown"
FAILED=0

verify_one() {
  local label="$1" address="$2" identifier="$3" args="$4" out rc
  local log
  log="$(mktemp)"
  echo "--- $label: $address"
  set +e
  "$FORGE" verify-contract "$address" "$identifier" \
    --chain "$CHAIN_ID" \
    --verifier etherscan \
    --constructor-args "$args" \
    --retries "$VERIFY_RETRIES" \
    --delay "$VERIFY_DELAY" \
    --watch >"$log" 2>&1
  rc=$?
  set -e
  cat "$log"
  out="$(tr '[:upper:]' '[:lower:]' <"$log")"
  rm -f "$log"
  if [[ "$out" == *"already verified"* ]]; then
    VERIFY_RESULT="already verified (skipped)"
    return 0
  fi
  if [ $rc -eq 0 ]; then
    VERIFY_RESULT="verified"
    return 0
  fi
  VERIFY_RESULT="FAILED (forge exit $rc, see the output above)"
  return 1
}

if verify_one "ERC20PeriodicalStaking" "$STAKING" \
  "src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol:ERC20PeriodicalStaking" "$STAKING_ARGS"; then
  STAKING_STATUS="$VERIFY_RESULT"
else
  STAKING_STATUS="$VERIFY_RESULT"
  FAILED=1
fi

if [ -n "${CONTROLLER:-}" ]; then
  echo
  if verify_one "LimitController" "$CONTROLLER" \
    "src/contracts/LimitController.sol:LimitController" "$CONTROLLER_ARGS"; then
    CONTROLLER_STATUS="$VERIFY_RESULT"
  else
    CONTROLLER_STATUS="$VERIFY_RESULT"
    FAILED=1
  fi
fi

echo
echo "=== Summary (chain $CHAIN_ID) ==="
show "ERC20PeriodicalStaking" "$STAKING"
show "  status" "$STAKING_STATUS"
show "LimitController" "${CONTROLLER:-<not verified: address unknown>}"
show "  status" "$CONTROLLER_STATUS"
if [ -z "${CONTROLLER:-}" ]; then
  echo "  Set VERIFY_CONTROLLER in ${ENV_FILE#"$ROOT"/} to verify the LimitController too."
fi
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "  A submission that was accepted but is still pending can be polled with:"
  echo "    ./script/verify-v050.sh $NETWORK --guid <the GUID printed above>"
  exit 1
fi
