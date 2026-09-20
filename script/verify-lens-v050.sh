#!/usr/bin/env bash
# Verify an already-deployed StakingLens on the block explorer. Sends no transaction.
#
#   ./script/verify-lens-v050.sh <polygon|amoy>
#
# Why this exists: with via_ir, solc 0.8.20 generates slightly different code for the same source depending on
# which files are compiled in the same batch. `forge script` compiles the lens together with DeployLens.s.sol,
# while `forge verify-contract` (and --verify) sends only the lens's own imports, so the explorer's rebuild does
# not match the deployed bytes ("bytecode does NOT match"). This script rebuilds the exact batch of the deploy,
# proves locally that it reproduces the bytes that were sent on chain, and only then submits that input.
#
# Reads deploy/v050/<network>.env for ETHERSCAN_API_KEY (or POLYGONSCAN_API_KEY). The key is passed to the helper
# through the environment and sent in the POST body, so it never appears in a command line.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

NETWORK="${1:-}"
case "$NETWORK" in
  polygon) CHAIN_ID=137;;
  amoy) CHAIN_ID=80002;;
  *) die "usage: $0 <polygon|amoy>";;
esac

ENV_FILE="$ROOT/deploy/v050/$NETWORK.env"
[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
set -a; # shellcheck disable=SC1090
source "$ENV_FILE"; set +a
VERIFY_KEY="${ETHERSCAN_API_KEY:-${POLYGONSCAN_API_KEY:-}}"
[ -n "$VERIFY_KEY" ] || die "ETHERSCAN_API_KEY is empty in $ENV_FILE"

BROADCAST_FILE="$ROOT/broadcast/DeployLens.s.sol/$CHAIN_ID/run-latest.json"
[ -f "$BROADCAST_FILE" ] || die "$BROADCAST_FILE not found: deploy the lens first (script/deploy-lens-v050.sh)"

cd "$ROOT"
LENS_VERIFY_KEY="$VERIFY_KEY" LENS_CHAIN_ID="$CHAIN_ID" LENS_ROOT="$ROOT" LENS_BROADCAST="$BROADCAST_FILE" python3 - <<'PY'
import glob, json, os, subprocess, sys, time, urllib.parse, urllib.request

root = os.environ["LENS_ROOT"] + "/"
chain_id = os.environ["LENS_CHAIN_ID"]
key = os.environ["LENS_VERIFY_KEY"]
LENS = "src/contracts/erc20-periodical-staking/StakingLens.sol"

def die(msg):
    print("ERROR:", msg, file=sys.stderr); sys.exit(1)

tx = [t for t in json.load(open(os.environ["LENS_BROADCAST"]))["transactions"] if t.get("contractName") == "StakingLens"]
if not tx: die("no StakingLens deployment in the broadcast record")
address = tx[-1]["contractAddress"]
sent = tx[-1]["transaction"]["input"][2:].lower()

infos = [json.load(open(f)) for f in glob.glob(root + "out/build-info/*.json")]
infos = [b for b in infos if any("DeployLens.s.sol" in p for p in b["source_id_to_path"].values())]
if len(infos) != 1:
    die(f"expected exactly one build-info with DeployLens.s.sol, found {len(infos)}: run the lens deploy simulation once, then retry")
ids = infos[0]["source_id_to_path"]
paths = [ids[k] for k in sorted(ids, key=int)]

art = json.load(open(root + "out/StakingLens.sol/StakingLens.json"))
meta = json.loads(art["rawMetadata"]); s = meta["settings"]
version = "v" + meta["compiler"]["version"]            # v0.8.20+commit.a1b79de6
solc = os.path.expanduser("~/.svm/" + meta["compiler"]["version"].split("+")[0] + "/solc-" + meta["compiler"]["version"].split("+")[0])
if not os.path.exists(solc): die(f"{solc} not found")

std = {
    "language": "Solidity",
    "sources": {p: {"content": open(root + p).read()} for p in paths},
    "settings": {
        "remappings": s["remappings"], "optimizer": s["optimizer"], "viaIR": True, "evmVersion": s["evmVersion"],
        "metadata": {"bytecodeHash": s["metadata"]["bytecodeHash"]}, "libraries": {},
        "outputSelection": {"*": {"*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object", "metadata"]}},
    },
}
print(f"rebuilding the deploy batch locally ({len(paths)} files, {version}) ...")
r = subprocess.run([solc, "--standard-json", "--base-path", root, "--allow-paths", root], input=json.dumps(std), capture_output=True, text=True, cwd=root)
out = json.loads(r.stdout)
errs = [e for e in out.get("errors", []) if e["severity"] == "error"]
if errs: die("local rebuild failed: " + errs[0]["formattedMessage"][:400])
built = out["contracts"][LENS]["StakingLens"]["evm"]["bytecode"]["object"].lower()
if not sent.startswith(built):
    die("the local rebuild does NOT reproduce the bytes that were sent on chain (src changed since the deploy?). Nothing was submitted.")
ctor_args = sent[len(built):]
print(f"local rebuild reproduces the deployed bytes ({len(built)//2} bytes). lens: {address}")

api = f"https://api.etherscan.io/v2/api?chainid={chain_id}"
def post(fields):
    req = urllib.request.Request(api, data=urllib.parse.urlencode(fields).encode(), headers={"User-Agent": "verify-lens-v050"})
    return json.loads(urllib.request.urlopen(req, timeout=120).read())

res = post({
    "apikey": key, "module": "contract", "action": "verifysourcecode", "contractaddress": address,
    "sourceCode": json.dumps(std), "codeformat": "solidity-standard-json-input",
    "contractname": LENS + ":StakingLens", "compilerversion": version,
    "constructorArguements": ctor_args, "constructorArguments": ctor_args,
})
print("submit:", res.get("message"), "-", str(res.get("result"))[:120])
if str(res.get("status")) != "1":
    if "already verified" in str(res.get("result")).lower(): sys.exit(0)
    die("the explorer refused the submission")
guid = res["result"]
for i in range(20):
    time.sleep(15)
    st = post({"apikey": key, "module": "contract", "action": "checkverifystatus", "guid": guid})
    print("status:", st.get("result"))
    result = str(st.get("result")).lower()
    if "pass" in result or "already verified" in result:
        print("VERIFIED"); sys.exit(0)
    if "pending" not in result: die("verification failed: " + str(st.get("result")))
die("still pending after 5 minutes; check the explorer page, or run this script again")
PY
