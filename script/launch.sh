#!/usr/bin/env bash
# Compile and start the local Solana demo. Leaves the validator running for script/test.sh.
# Does not read ALCH_KEY, does not deploy a workflow, and does not broadcast to a public cluster.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

unset ALCH_KEY

SBF_RUST="${HOME}/.cache/solana/v1.57/platform-tools/rust/bin"
if [[ ! -x "${SBF_RUST}/rustc" ]]; then
  echo "Solana platform-tools rustc is missing under ${SBF_RUST}" >&2
  exit 1
fi
# cargo-build-sbf --no-rustup-override uses the first rustc on PATH.
export PATH="${SBF_RUST}:${HOME}/.local/share/solana/install/active_release/bin:${HOME}/.bun/bin:${HOME}/.cre/bin:${PATH}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-8}"

if ! command -v cre >/dev/null 2>&1; then
  echo "cre is not on PATH. Install it from https://docs.chain.link/cre" >&2
  exit 1
fi
if ! command -v bun >/dev/null 2>&1; then
  echo "bun is not on PATH. CRE compiles the TypeScript workflow with bun." >&2
  exit 1
fi
if ! command -v solana-test-validator >/dev/null 2>&1 || ! command -v cargo-build-sbf >/dev/null 2>&1; then
  echo "solana-test-validator and cargo-build-sbf must be on PATH" >&2
  exit 1
fi
if ! cre whoami >/dev/null 2>&1; then
  echo "cre workflow simulate needs a CRE account. Run: cre login" >&2
  echo "Or export CRE_API_KEY from https://app.chain.link. Do not write the key into the repo." >&2
  exit 1
fi

RPC="${RPC:-http://127.0.0.1:8899}"
PORT="${PORT:-8899}"
KEYS="${ROOT}/keys"
THRESHOLD=1000000000
MIN_PRE=10000000000
BOUNTY_LAMPORTS_PAY=10000000000
DEPOSIT=10000000000
FORWARDER_PROGRAM=GFrSSvQXaVGkc6Nrr8y2msie6pivJkR1s2EnDk4et294
FORWARDER_STATE=9FgdPyU28bGMCuJyD34pzw9W7Ys36ziLbT9cbZtsaraV
MAINNET_RPC="${MAINNET_RPC:-https://api.mainnet-beta.solana.com}"

if solana cluster-version --url "${RPC}" >/dev/null 2>&1; then
  echo "port ${PORT} is already serving RPC. Stop that validator before launching again." >&2
  exit 1
fi

mkdir -p proofs "${KEYS}"
VALIDATOR_PID=
KEEP_VALIDATOR=0
cleanup() {
  if [[ "${KEEP_VALIDATOR}" != 1 && -n "${VALIDATOR_PID}" ]] && kill -0 "${VALIDATOR_PID}" 2>/dev/null; then
    kill "${VALIDATOR_PID}" 2>/dev/null || true
    wait "${VALIDATOR_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

keygen() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    solana-keygen new --silent --no-bip39-passphrase --force -o "${path}" >/dev/null
  fi
}

for name in payer forwarder attacker payout vault-program bounty-program vault-buffer bounty-buffer; do
  keygen "${KEYS}/${name}.json"
done
chmod 700 "${KEYS}"
chmod 600 "${KEYS}"/*.json

VAULT_PROGRAM_ID="$(solana-keygen pubkey "${KEYS}/vault-program.json")"
BOUNTY_PROGRAM_ID="$(solana-keygen pubkey "${KEYS}/bounty-program.json")"
export RPC KEYS VAULT_PROGRAM_ID BOUNTY_PROGRAM_ID

printf 'solana_program::declare_id!("%s");\n' "${VAULT_PROGRAM_ID}" > programs/vulnerable_vault/src/id.rs
printf 'solana_program::declare_id!("%s");\n' "${BOUNTY_PROGRAM_ID}" > programs/cre_bounty/src/id.rs

echo "== build vault and bounty =="
cargo-build-sbf --no-rustup-override --manifest-path programs/vulnerable_vault/Cargo.toml
cargo-build-sbf --no-rustup-override --manifest-path programs/cre_bounty/Cargo.toml

echo "== install workflow deps =="
(cd bounty-cre && bun install --frozen-lockfile)
(cd script && bun install)

echo "== solana-test-validator mainnet fork =="
python3 -c '
import os, sys
log = sys.argv[1]
args = sys.argv[2:]
os.setsid()
fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.dup2(fd, 1)
os.dup2(fd, 2)
os.close(fd)
devnull = os.open("/dev/null", os.O_RDONLY)
os.dup2(devnull, 0)
os.close(devnull)
os.execvp(args[0], args)
' "${ROOT}/proofs/solana-validator.log" \
  solana-test-validator \
  --reset \
  --ledger "${ROOT}/proofs/test-ledger" \
  --url "${MAINNET_RPC}" \
  --clone-feature-set \
  --clone-upgradeable-program "${FORWARDER_PROGRAM}" \
  --clone "${FORWARDER_STATE}" \
  --bind-address 127.0.0.1 \
  --rpc-port "${PORT}" &
VALIDATOR_PID=$!

ready=0
for _ in $(seq 1 300); do
  if ! kill -0 "${VALIDATOR_PID}" 2>/dev/null; then
    echo "validator exited before RPC came up" >&2
    tail -40 proofs/solana-validator.log >&2 || true
    exit 1
  fi
  if solana cluster-version --url "${RPC}" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if (( ready == 0 )); then
  echo "validator RPC did not answer on ${RPC}" >&2
  tail -40 proofs/solana-validator.log >&2 || true
  exit 1
fi

python3 - "${RPC}" "${MAINNET_RPC}" "${FORWARDER_PROGRAM}" "${FORWARDER_STATE}" << 'PY'
import json, sys, urllib.request
local, mainnet, program, state = sys.argv[1:]

def info(url, key):
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "getAccountInfo",
        "params": [key, {"encoding": "base64"}],
    }).encode()
    req = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.load(resp)
    value = (data.get("result") or {}).get("value")
    if value is None:
        raise SystemExit(f"missing {key} at {url}")
    return value["owner"], value["lamports"]

for key in (program, state):
    local_info = info(local, key)
    mainnet_info = info(mainnet, key)
    if local_info != mainnet_info:
        raise SystemExit(f"fork mismatch {key} local={local_info} mainnet={mainnet_info}")
    print(f"FORK_OK account={key} owner={local_info[0]} lamports={local_info[1]}")
PY

echo "== airdrop =="
airdrop() {
  local amount="$1"
  local pk="$2"
  solana airdrop "${amount}" "${pk}" --url "${RPC}" >/dev/null
}
airdrop 100 "$(solana-keygen pubkey "${KEYS}/payer.json")"
airdrop 10 "$(solana-keygen pubkey "${KEYS}/attacker.json")"
airdrop 2 "$(solana-keygen pubkey "${KEYS}/forwarder.json")"
airdrop 2 "$(solana-keygen pubkey "${KEYS}/payout.json")"

echo "== deploy vault and bounty =="
solana program deploy \
  --url "${RPC}" \
  --keypair "${KEYS}/payer.json" \
  --program-id "${KEYS}/vault-program.json" \
  --buffer "${KEYS}/vault-buffer.json" \
  programs/vulnerable_vault/target/deploy/vulnerable_vault.so
solana program deploy \
  --url "${RPC}" \
  --keypair "${KEYS}/payer.json" \
  --program-id "${KEYS}/bounty-program.json" \
  --buffer "${KEYS}/bounty-buffer.json" \
  programs/cre_bounty/target/deploy/cre_bounty.so

python3 - "${RPC}" "${VAULT_PROGRAM_ID}" "${BOUNTY_PROGRAM_ID}" << 'PY'
import json, sys, time, urllib.request
rpc, *programs = sys.argv[1:]

def executable(key):
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "getAccountInfo",
        "params": [key, {"encoding": "base64", "commitment": "confirmed"}],
    }).encode()
    req = urllib.request.Request(rpc, data=body, headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.load(resp)
    value = (data.get("result") or {}).get("value")
    return bool(value and value.get("executable"))

def slot():
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "getSlot",
        "params": [{"commitment": "processed"}],
    }).encode()
    req = urllib.request.Request(rpc, data=body, headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.load(resp)
    return int(data["result"])

for key in programs:
    ready = False
    for _ in range(40):
        if executable(key):
            print(f"PROGRAM_READY {key}")
            ready = True
            break
        time.sleep(0.5)
    if not ready:
        raise SystemExit(f"program {key} is not executable")

seen = slot()
for _ in range(50):
    now = slot()
    if now > seen:
        print(f"SLOT_ADVANCED {seen} {now}")
        break
    time.sleep(0.2)
else:
    raise SystemExit("validator slot did not advance after deploy")
PY

echo "== chain init =="
(cd script && bun --silent chain.ts init)
eval "$(cd script && bun --silent chain.ts print-addresses)"
if [[ -z "${VAULT:-}" || -z "${BOUNTY:-}" || -z "${FORWARDER:-}" ]]; then
  echo "chain init did not print vault and bounty addresses" >&2
  exit 1
fi

umask 077
cat > proofs/launch.env << EOF
RPC=${RPC}
PORT=${PORT}
VALIDATOR_PID=${VALIDATOR_PID}
VAULT=${VAULT}
BOUNTY=${BOUNTY}
VAULT_PROGRAM_ID=${VAULT_PROGRAM_ID}
BOUNTY_PROGRAM_ID=${BOUNTY_PROGRAM_ID}
FORWARDER=${FORWARDER}
THRESHOLD=${THRESHOLD}
MIN_PRE=${MIN_PRE}
BOUNTY_LAMPORTS_PAY=${BOUNTY_LAMPORTS_PAY}
DEPOSIT=${DEPOSIT}
KEYS=${KEYS}
EOF

EXAMPLE_PAYOUT="$(solana-keygen pubkey "${KEYS}/payout.json")"
KEEP_VALIDATOR=1
echo "vault ${VAULT}"
echo "bounty ${BOUNTY}"
echo "validator ${VALIDATOR_PID}"
echo "LAUNCH_OK"
echo "submit with: bash script/test.sh ${EXAMPLE_PAYOUT}"
echo "stop the validator with: kill ${VALIDATOR_PID}"
