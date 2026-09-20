#!/usr/bin/env bash
# Deploy the read-only StakingLens for an already-deployed ERC20PeriodicalStaking v0.5.0.
#
#   ./script/deploy-lens-v050.sh <polygon|amoy> <staking address>               # simulate (no transactions)
#   ./script/deploy-lens-v050.sh <polygon|amoy> <staking address> --broadcast   # send
#
# Uses the same env file as deploy-v050.sh (deploy/v050/<network>.env): RPC_URL, DEPLOYER_ADDRESS and
# DEPLOYER_ACCOUNT (Foundry keystore), and verifies on the explorer when ETHERSCAN_API_KEY is set there.
# The env file is loaded inside this script only, so RPC_URL (it may hold a provider key) never enters your shell.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

NETWORK="${1:-}"; STAKING_ADDR="${2:-}"; MODE="${3:-}"
case "$NETWORK" in polygon|amoy) ;; *) die "usage: $0 <polygon|amoy> <staking address> [--broadcast]";; esac
[[ "$STAKING_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "second argument must be the staking contract address (0x + 40 hex), got '${STAKING_ADDR:-<empty>}'"
BROADCAST=false
case "$MODE" in "") ;; --broadcast) BROADCAST=true;; *) die "unknown option '$MODE' (only --broadcast)";; esac

ENV_FILE="$ROOT/deploy/v050/$NETWORK.env"
[ -f "$ENV_FILE" ] || die "$ENV_FILE not found: cp deploy/v050/$NETWORK.env.example deploy/v050/$NETWORK.env and fill it in"
set -a; # shellcheck disable=SC1090
source "$ENV_FILE"; set +a

[ -n "${RPC_URL:-}" ] || die "RPC_URL is empty in $ENV_FILE"
[[ "${DEPLOYER_ADDRESS:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "DEPLOYER_ADDRESS in $ENV_FILE must be a 0x address"

cd "$ROOT"
# Same patience as deploy-v050.sh: public endpoints time out and drop requests.
RPC_TIMEOUT="${RPC_TIMEOUT:-120}"
TX_TIMEOUT="${TX_TIMEOUT:-600}"
VERIFY_RETRIES="${VERIFY_RETRIES:-10}"
VERIFY_DELAY="${VERIFY_DELAY:-15}"
HAS_VERIFY_KEY=false
[ -n "${ETHERSCAN_API_KEY:-${POLYGONSCAN_API_KEY:-}}" ] && HAS_VERIFY_KEY=true

ARGS=(script/DeployLens.s.sol --rpc-url deploy-v050 --sender "$DEPLOYER_ADDRESS" --rpc-timeout "$RPC_TIMEOUT")
if $BROADCAST; then
  [ -n "${DEPLOYER_ACCOUNT:-}" ] || die "DEPLOYER_ACCOUNT (Foundry keystore name) is empty in $ENV_FILE; refusing to broadcast without a keystore"
  ARGS+=(--account "$DEPLOYER_ACCOUNT" --broadcast --slow --timeout "$TX_TIMEOUT")
  if $HAS_VERIFY_KEY; then
    export ETHERSCAN_API_KEY="${ETHERSCAN_API_KEY:-$POLYGONSCAN_API_KEY}"
    ARGS+=(--verify --retries "$VERIFY_RETRIES" --delay "$VERIFY_DELAY")
  fi
fi

echo "=== deploy-lens-v050: $NETWORK ==="
echo "  staking : $STAKING_ADDR"
echo "  sender  : $DEPLOYER_ADDRESS"
echo "  mode    : $($BROADCAST && echo 'BROADCAST' || echo 'simulation (no transactions)')"
echo "  verify  : $($HAS_VERIFY_KEY && { $BROADCAST && echo yes || echo 'yes, on --broadcast (a simulation never verifies)'; } || echo 'no (no ETHERSCAN_API_KEY in the env file)')"
echo

if $BROADCAST; then
  # Never retried automatically: a second run after a half-sent first one must be a human decision.
  STAKING="$STAKING_ADDR" forge script "${ARGS[@]}"
else
  # A simulation sends nothing, so it is safe to retry when the public RPC drops a request.
  n=0
  until STAKING="$STAKING_ADDR" forge script "${ARGS[@]}"; do
    n=$((n + 1))
    [ "$n" -ge 3 ] && die "the simulation failed 3 times. If the error is an RPC timeout, wait a minute and run it again, or point RPC_URL in $ENV_FILE at another endpoint"
    echo; echo "  simulation failed (attempt $n of 3), retrying in 10 s..."; sleep 10
  done
fi

if $BROADCAST; then
  echo
  echo "Give the StakingLens address printed above to the frontend (VIP_STAKE_V050_LENS_ADDRESS),"
  echo "together with the staking address (VIP_STAKE_V050_ADDRESS)."
fi
