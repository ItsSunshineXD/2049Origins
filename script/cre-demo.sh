#!/usr/bin/env bash
# Local CRE simulate demo. The confidential handler eth_calls anvil.
# This script does not read ALCH_KEY, does not deploy a workflow, and does not
# call the production DON.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

unset ALCH_KEY

export PATH="${HOME}/.bun/bin:${HOME}/.cre/bin:${HOME}/.foundry/bin:${PATH}"

# 检查CRE bun命令行工具是否存在
if ! command -v cre >/dev/null 2>&1; then
  echo "cre is not on PATH. Install it from https://docs.chain.link/cre" >&2
  exit 1
fi
if ! command -v bun >/dev/null 2>&1; then
  echo "bun is not on PATH. CRE compiles the TypeScript workflow with bun." >&2
  exit 1
fi
# 检查CRE是否已登录
if ! cre whoami >/dev/null 2>&1; then
  echo "cre workflow simulate needs a CRE account. Run: cre login" >&2
  echo "Or export CRE_API_KEY from https://app.chain.link. Do not write the key into the repo." >&2
  exit 1
fi

RPC="${RPC:-http://127.0.0.1:18545}"
PORT="${PORT:-18545}"
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PAYOUT=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
FORWARDER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
WORKFLOW_OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
WORKFLOW_NAME=bounty-cre
WORKFLOW_ID="$(cast keccak "bounty-cre-local-simulate")"
CALLER="$WORKFLOW_OWNER"
THRESHOLD=1000000000000000000
ATTACK_VALUE=1000000000000000000
EXPECTED_PRE=10000000000000000000
EXPECTED_POST=0
EXPECTED_PAYOUT=10000000000000000000

if cast block-number --rpc-url "${RPC}" >/dev/null 2>&1; then
  echo "port ${PORT} is already serving RPC. Stop that anvil before the CRE demo." >&2
  exit 1
fi

mkdir -p proofs
ENVFILE="$(mktemp /tmp/cre-demo-env.XXXXXX)"
CONFIG="$(mktemp /tmp/cre-demo-config.XXXXXX.json)"
ANVIL_PID=
cleanup() {
  if [[ -n "${ANVIL_PID}" ]] && kill -0 "${ANVIL_PID}" 2>/dev/null; then
    kill "${ANVIL_PID}" 2>/dev/null || true
    wait "${ANVIL_PID}" 2>/dev/null || true
  fi
  rm -f "${ENVFILE}" "${CONFIG}"
}
trap cleanup EXIT INT TERM

compile_creation() {
  local solc_bin="${SOLC:-}"
  if [[ -z "${solc_bin}" ]]; then
    if [[ -x "${HOME}/.local/share/svm/0.8.28/solc-0.8.28" ]]; then
      solc_bin="${HOME}/.local/share/svm/0.8.28/solc-0.8.28"
    elif [[ -x "${HOME}/.svm/0.8.28/solc-0.8.28" ]]; then
      solc_bin="${HOME}/.svm/0.8.28/solc-0.8.28"
    elif command -v solc >/dev/null 2>&1; then
      solc_bin="$(command -v solc)"
    else
      echo "solc 0.8.28 not found" >&2
      exit 1
    fi
  fi
  python3 - "${solc_bin}" "${ROOT}/examples/reentrancy/Deployer.sol" << 'PY'
import json, subprocess, sys
solc, path = sys.argv[1], sys.argv[2]
source = open(path, encoding="utf-8").read()
std = {
    "language": "Solidity",
    "sources": {"Deployer.sol": {"content": source}},
    "settings": {
        "optimizer": {"enabled": True, "runs": 200},
        "evmVersion": "cancun",
        "outputSelection": {"*": {"*": ["evm.bytecode.object"]}},
    },
}
proc = subprocess.run([solc, "--standard-json"], input=json.dumps(std), text=True, capture_output=True)
if proc.returncode != 0:
    sys.stderr.write(proc.stderr)
    sys.exit(proc.returncode)
out = json.loads(proc.stdout)
errors = [e for e in out.get("errors", []) if e.get("severity") == "error"]
if errors:
    sys.stderr.write(json.dumps(errors))
    sys.exit(1)
obj = out["contracts"]["Deployer.sol"]["AttackDeployer"]["evm"]["bytecode"]["object"]
if len(obj) < 100 or len(obj) % 2 != 0:
    sys.stderr.write("creation bytecode missing\n")
    sys.exit(1)
sys.stdout.write("0x" + obj)
PY
}

if [[ ! -f "${ROOT}/lib/forge-std/src/Script.sol" ]]; then
  echo "cre/lib/forge-std is missing. From cre/: git clone --depth 1 --branch v1.17.0 https://github.com/foundry-rs/forge-std.git lib/forge-std" >&2
  exit 1
fi

echo "== compile bounty =="
forge build >/dev/null

echo "== anvil chain 11155111 =="
anvil --chain-id 11155111 --port "${PORT}" --silent >proofs/cre-anvil.log 2>&1 &
ANVIL_PID=$!
ready=0
for _ in $(seq 1 50); do
  if cast block-number --rpc-url "${RPC}" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "${ANVIL_PID}" 2>/dev/null; then
    echo "anvil exited before it was ready" >&2
    cat proofs/cre-anvil.log >&2
    exit 1
  fi
  sleep 0.2
done
if [[ "${ready}" != 1 ]]; then
  echo "anvil did not answer on ${RPC}" >&2
  exit 1
fi

echo "== deploy vault and CreBounty =="
if ! WORKFLOW_ID="${WORKFLOW_ID}" \
  WORKFLOW_NAME="${WORKFLOW_NAME}" \
  WORKFLOW_OWNER="${WORKFLOW_OWNER}" \
  forge script script/CreDemo.s.sol:CreDemo \
    --rpc-url "${RPC}" \
    --private-key "${KEY}" \
    --broadcast \
    --non-interactive \
    >proofs/cre-setup.log 2>&1; then
  cat proofs/cre-setup.log >&2
  exit 1
fi
pick() { grep -oE "${1}=0x[0-9a-fA-F]+|${1}=[0-9]+" proofs/cre-setup.log | tail -1 | cut -d= -f2-; }
VAULT="$(pick DEMO_VAULT)"
BOUNTY="$(pick DEMO_BOUNTY)"
PROTECTION_ID="$(pick DEMO_PROTECTION)"
if [[ -z "${VAULT}" || -z "${BOUNTY}" || -z "${PROTECTION_ID}" ]]; then
  echo "setup log did not contain the deployment addresses" >&2
  exit 1
fi
echo "vault ${VAULT}"
echo "bounty ${BOUNTY}"
echo "protection ${PROTECTION_ID}"

echo "== compile unpublished creation =="
CREATION="$(compile_creation)"
echo "creation bytecode bytes $(( (${#CREATION} - 2) / 2 ))"
umask 077
printf 'SECRET_CREATION_CODE=%s\n' "${CREATION}" > "${ENVFILE}"
export SECRET_CREATION_CODE="${CREATION}"
unset CREATION

python3 - "${CONFIG}" "${VAULT}" "${BOUNTY}" "${CALLER}" "${PAYOUT}" "${THRESHOLD}" "${ATTACK_VALUE}" << 'PY'
import json, sys
path, vault, bounty, caller, payout, threshold, value = sys.argv[1:]
json.dump(
    {
        "schedule": "0 */1 * * * *",
        "rpcUrl": "http://127.0.0.1:18545",
        "secretId": "CREATION_CODE",
        "chainId": "11155111",
        "vault": vault,
        "bounty": bounty,
        "caller": caller,
        "payout": payout,
        "value": value,
        "threshold": threshold,
    },
    open(path, "w", encoding="utf-8"),
)
PY

echo "== install workflow deps =="
(cd "${ROOT}/bounty-cre" && bun install --frozen-lockfile)

echo "== cre workflow simulate =="
set +e
cre workflow simulate bounty-cre \
  --target staging-settings \
  --non-interactive \
  --trigger-index 0 \
  --config "${CONFIG}" \
  --env "${ENVFILE}" \
  >proofs/cre-simulate.log 2>&1
SIM_STATUS=$?
set -e
if [[ "${SIM_STATUS}" -ne 0 ]]; then
  echo "cre workflow simulate failed" >&2
  python3 - "${ENVFILE}" proofs/cre-simulate.log << 'PY'
import pathlib, sys
env = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").split("=", 1)[1].strip()
text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
bare = env[2:] if env.startswith("0x") else env
text = text.replace(env, "[creation-code]").replace(bare, "[creation-code]")
sys.stderr.write(text)
PY
  exit "${SIM_STATUS}"
fi

JOURNAL="$(grep -oE 'CRE_JOURNAL=0x[0-9a-fA-F]+' proofs/cre-simulate.log | tail -1 | cut -d= -f2- || true)"
if [[ -z "${JOURNAL}" ]]; then
  echo "simulate log has no CRE_JOURNAL line" >&2
  python3 - "${ENVFILE}" proofs/cre-simulate.log << 'PY'
import pathlib, sys
env = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").split("=", 1)[1].strip()
text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
bare = env[2:] if env.startswith("0x") else env
sys.stderr.write(text.replace(env, "[creation-code]").replace(bare, "[creation-code]"))
PY
  exit 1
fi

field() {
  printf '%s\n' "${DECODED}" | sed -n "${1}p" | awk '{print $1}'
}
DECODED="$(cast decode-abi "journal()(uint256,address,address,uint64,bytes32,uint256,uint256,uint256,address)" "${JOURNAL}")"
PRE="$(field 7)"
POST="$(field 8)"
echo "journal pre ${PRE} post ${POST}"
if [[ "${PRE}" != "${EXPECTED_PRE}" || "${POST}" != "${EXPECTED_POST}" ]]; then
  echo "journal balances are not 10 ETH then 0" >&2
  exit 1
fi

# The handler anchored on the latest sealed block. blockhash(current) is 0,
# so mine one empty block before onReport. Same class of bug as the RISC0 reveal.
echo "== mine one block then onReport =="
cast rpc evm_mine --rpc-url "${RPC}" >/dev/null
PAYOUT_BEFORE="$(cast balance "${PAYOUT}" --rpc-url "${RPC}")"

WID="$(cast call "${BOUNTY}" "workflowId()(bytes32)" --rpc-url "${RPC}")"
WNAME="$(cast call "${BOUNTY}" "workflowName()(bytes10)" --rpc-url "${RPC}")"
WOWNER="$(cast call "${BOUNTY}" "workflowOwner()(address)" --rpc-url "${RPC}")"
META="$(
  python3 - "${WID}" "${WNAME}" "${WOWNER}" << 'PY'
import sys
def strip(value):
    value = value.strip().split()[0]
    return value[2:] if value.startswith("0x") or value.startswith("0X") else value

wid, name, owner = (strip(x) for x in sys.argv[1:])
if len(name) > 20:
    # bytes10 is left-aligned when cast prints a full word.
    name = name[:20]
if len(wid) != 64 or len(name) != 20 or len(owner) != 40:
    raise SystemExit(f"unexpected identity widths {len(wid)} {len(name)} {len(owner)}")
# 64 bytes: identity plus a trailing report id, matching KeystoneForwarder.
raw = bytes.fromhex(wid + name + owner + "0001")
sys.stdout.write("0x" + raw.hex())
PY
)"

cast send "${BOUNTY}" "onReport(bytes,bytes)" "${META}" "${JOURNAL}" \
  --unlocked \
  --from "${FORWARDER}" \
  --rpc-url "${RPC}" >/dev/null

PAUSED="$(cast call "${VAULT}" "paused()(bool)" --rpc-url "${RPC}")"
BOUNTY_BAL="$(cast balance "${BOUNTY}" --rpc-url "${RPC}")"
PAYOUT_AFTER="$(cast balance "${PAYOUT}" --rpc-url "${RPC}")"
python3 - "${PAUSED}" "${BOUNTY_BAL}" "${PAYOUT_BEFORE}" "${PAYOUT_AFTER}" "${EXPECTED_PAYOUT}" << 'PY'
import sys
paused, bounty_bal, before, after, expected = sys.argv[1:]
if paused != "true":
    raise SystemExit(f"vault not paused ({paused})")
if int(bounty_bal) != 0:
    raise SystemExit(f"bounty balance {bounty_bal}")
if int(after) - int(before) != int(expected):
    raise SystemExit(f"payout delta {int(after) - int(before)}")
PY

echo "CRE_DEMO_OK"
