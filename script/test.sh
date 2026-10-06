#!/usr/bin/env bash
# Submit one unpublished flash-loan exploit and claim the bounty.
# Does not stop the validator started by script/launch.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

unset ALCH_KEY

if [[ $# -ne 1 ]]; then
  echo "usage: bash script/test.sh <payout-address>" >&2
  exit 1
fi
PAYOUT="$1"

export PATH="${HOME}/.local/share/solana/install/active_release/bin:${HOME}/.bun/bin:${HOME}/.cre/bin:${PATH}"

if [[ ! -f proofs/launch.env ]]; then
  echo "proofs/launch.env is missing. Run: bash script/launch.sh" >&2
  exit 1
fi
# shellcheck disable=SC1091
source proofs/launch.env
export RPC KEYS VAULT_PROGRAM_ID BOUNTY_PROGRAM_ID

if [[ ! "${PAYOUT}" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]]; then
  echo "payout is not a base58 address" >&2
  exit 1
fi
if [[ "${PAYOUT}" == "${VAULT}" || "${PAYOUT}" == "${BOUNTY}" ]]; then
  echo "payout must not be the vault or the bounty" >&2
  exit 1
fi
if ! solana cluster-version --url "${RPC}" >/dev/null 2>&1; then
  echo "validator is not answering on ${RPC}. Run: bash script/launch.sh" >&2
  exit 1
fi

python3 - "${RPC}" "${PAYOUT}" << 'PY'
import json, sys, urllib.request
rpc, payout = sys.argv[1:]
body = json.dumps({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "getAccountInfo",
    "params": [payout, {"encoding": "base64", "commitment": "confirmed"}],
}).encode()
req = urllib.request.Request(rpc, data=body, headers={"content-type": "application/json"})
with urllib.request.urlopen(req, timeout=20) as resp:
    data = json.load(resp)
value = (data.get("result") or {}).get("value")
if value is None:
    raise SystemExit("payout account must already exist")
PY

ENVFILE="$(mktemp /tmp/cre-solana-env.XXXXXX)"
CONFIG="$(mktemp /tmp/cre-solana-config.XXXXXX.json)"
TX=
CLEANED=0
cleanup() {
  local status=$?
  if (( CLEANED )); then
    exit "${status}"
  fi
  CLEANED=1
  if [[ -n "${TX}" && -f proofs/cre-simulate.log ]]; then
    python3 - "${TX}" "${PAYOUT}" proofs/cre-simulate.log << 'PY'
import pathlib, sys
tx, payout, path = sys.argv[1:]
file = pathlib.Path(path)
text = file.read_text(errors="replace")
secret = f"{payout}:{tx}"
if secret in text:
    text = text.replace(secret, "[redacted]")
if tx and tx in text:
    text = text.replace(tx, "[redacted]")
file.write_text(text)
PY
  fi
  rm -f "${ENVFILE}" "${CONFIG}"
  exit "${status}"
}
trap cleanup EXIT INT TERM

echo "== repaid flash loan leaves the vault where it was =="
HONEST_TX="$(cd script && bun --silent chain.ts attack-tx honest)"
HONEST_OBS="$(printf '%s' "${HONEST_TX}" | (cd script && bun --silent chain.ts observe))"
HONEST_POST="$(printf '%s\n' "${HONEST_OBS}" | sed -n 's/.*post=\([0-9][0-9]*\).*/\1/p')"
echo "${HONEST_OBS}"
if [[ -z "${HONEST_POST}" ]] || (( HONEST_POST < THRESHOLD )); then
  echo "repaid flash loan crossed the threshold: ${HONEST_OBS}" >&2
  exit 1
fi

echo "== exploit transaction =="
TX="$(cd script && bun --silent chain.ts attack-tx exploit)"
if [[ ! "${TX}" =~ ^[A-Za-z0-9+/]+=*$ ]] || (( ${#TX} < 80 )); then
  echo "attack transaction was not base64" >&2
  exit 1
fi
umask 077
printf 'SECRET_ATTACK_TX=%s:%s\n' "${PAYOUT}" "${TX}" > "${ENVFILE}"
chmod 600 "${ENVFILE}"

python3 - "${CONFIG}" "${VAULT}" "${BOUNTY}" "${THRESHOLD}" << 'PY'
import json, sys
path, vault, bounty, threshold = sys.argv[1:]
with open(path, "w", encoding="utf-8") as fh:
    json.dump({
        "schedule": "0 */1 * * * *",
        "rpcUrl": "http://127.0.0.1:8899",
        "secretId": "ATTACK_TX",
        "vault": vault,
        "bounty": bounty,
        "threshold": threshold,
    }, fh)
PY

echo "== workflow =="
set +e
CRE_SOLANA_PRIVATE_KEY="${KEYS}/forwarder.json" \
cre workflow simulate bounty-cre \
  --target staging-settings \
  --non-interactive \
  --trigger-index 0 \
  --config "${CONFIG}" \
  --env "${ENVFILE}" \
  >proofs/cre-simulate.log 2>&1
sim_status=$?
set -e
if (( sim_status != 0 )); then
  echo "cre workflow simulate failed" >&2
  python3 - "${TX}" "${PAYOUT}" proofs/cre-simulate.log << 'PY'
import pathlib, sys
tx, payout, path = sys.argv[1:]
file = pathlib.Path(path)
text = file.read_text(errors="replace")
secret = f"{payout}:{tx}"
text = text.replace(secret, "[redacted]").replace(tx, "[redacted]")
sys.stdout.write("\n".join(text.splitlines()[-50:]) + "\n")
PY
  exit "${sim_status}"
fi

mapfile -t journals < <(grep -oE 'SOLANA_JOURNAL pre=[0-9]+ post=[0-9]+ slot=[0-9]+ payout=[1-9A-HJ-NP-Za-km-z]+' proofs/cre-simulate.log || true)
if (( ${#journals[@]} == 0 )); then
  echo "simulate log has no SOLANA_JOURNAL" >&2
  exit 1
fi
uniq_count="$(printf '%s\n' "${journals[@]}" | sort -u | wc -l)"
if (( uniq_count != 1 )); then
  echo "simulate log has conflicting journals" >&2
  printf '%s\n' "${journals[@]}" >&2
  exit 1
fi
JOURNAL="${journals[0]}"
REPORT="$(grep -oE 'SOLANA_REPORT=0x[0-9a-f]{192}' proofs/cre-simulate.log | tail -1 | cut -d= -f2- || true)"
if [[ -z "${REPORT}" ]]; then
  echo "simulate log has no 96-byte SOLANA_REPORT" >&2
  exit 1
fi
PRE="$(printf '%s\n' "${JOURNAL}" | sed -n 's/.*pre=\([0-9][0-9]*\).*/\1/p')"
POST="$(printf '%s\n' "${JOURNAL}" | sed -n 's/.*post=\([0-9][0-9]*\).*/\1/p')"
SLOT="$(printf '%s\n' "${JOURNAL}" | sed -n 's/.*slot=\([0-9][0-9]*\).*/\1/p')"
JOURNAL_PAYOUT="$(printf '%s\n' "${JOURNAL}" | sed -n 's/.*payout=\([1-9A-HJ-NP-Za-km-z][1-9A-HJ-NP-Za-km-z]*\).*/\1/p')"
printf '%s' "${TX}" | (cd script && bun --silent chain.ts observe) | tee /tmp/cre-solana-observed.txt
OBSERVED="$(cat /tmp/cre-solana-observed.txt)"
rm -f /tmp/cre-solana-observed.txt
OBS_PRE="$(printf '%s\n' "${OBSERVED}" | sed -n 's/.*pre=\([0-9][0-9]*\).*/\1/p')"
OBS_POST="$(printf '%s\n' "${OBSERVED}" | sed -n 's/.*post=\([0-9][0-9]*\).*/\1/p')"
echo "${JOURNAL}"
echo "${OBSERVED}"
if [[ "${PRE}" != "${OBS_PRE}" || "${POST}" != "${OBS_POST}" || "${JOURNAL_PAYOUT}" != "${PAYOUT}" ]]; then
  echo "journal does not match the simulated withdraw" >&2
  exit 1
fi
if (( PRE < MIN_PRE || POST <= 0 || POST >= THRESHOLD )); then
  echo "predicate failed pre=${PRE} post=${POST}" >&2
  exit 1
fi

read_status() {
  VAULT_LAMPORTS=""
  VAULT_PAUSED=""
  BOUNTY_LAMPORTS=""
  PAYOUT_LAMPORTS=""
  local key value
  while IFS='=' read -r key value; do
    case "${key}" in
      VAULT_LAMPORTS) VAULT_LAMPORTS="${value}" ;;
      VAULT_PAUSED) VAULT_PAUSED="${value}" ;;
      BOUNTY_LAMPORTS) BOUNTY_LAMPORTS="${value}" ;;
      PAYOUT_LAMPORTS) PAYOUT_LAMPORTS="${value}" ;;
    esac
  done < <(cd script && bun --silent chain.ts status "${PAYOUT}")
}

read_status
PAYOUT_BEFORE="${PAYOUT_LAMPORTS}"
BOUNTY_BEFORE="${BOUNTY_LAMPORTS}"
VAULT_BEFORE="${VAULT_LAMPORTS}"

echo "== submit report =="
(cd script && bun --silent chain.ts submit "${REPORT}")
read_status
if [[ "${VAULT_PAUSED}" != "1" ]]; then
  echo "vault is not paused" >&2
  exit 1
fi
if (( PAYOUT_LAMPORTS - PAYOUT_BEFORE != BOUNTY_LAMPORTS_PAY )); then
  echo "payout delta is ${PAYOUT_LAMPORTS} - ${PAYOUT_BEFORE}" >&2
  exit 1
fi
if (( BOUNTY_BEFORE - BOUNTY_LAMPORTS != BOUNTY_LAMPORTS_PAY )); then
  echo "bounty delta is ${BOUNTY_BEFORE} - ${BOUNTY_LAMPORTS}" >&2
  exit 1
fi
if (( VAULT_LAMPORTS < MIN_PRE || VAULT_LAMPORTS != VAULT_BEFORE )); then
  echo "on-chain vault balance changed: before=${VAULT_BEFORE} after=${VAULT_LAMPORTS}" >&2
  exit 1
fi
echo "honest post=${HONEST_POST}"
echo "VAULT_LAMPORTS=${VAULT_LAMPORTS}"
echo "VAULT_PAUSED=${VAULT_PAUSED}"
echo "BOUNTY_LAMPORTS=${BOUNTY_LAMPORTS}"
echo "PAYOUT_LAMPORTS=${PAYOUT_LAMPORTS}"
echo "CRE_DEMO_OK"
