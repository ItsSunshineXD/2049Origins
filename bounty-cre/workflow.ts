import { cre, hexToBase64, json, ok, type TeeRuntime } from '@chainlink/cre-sdk'
import { bytesToHex, stringToHex } from 'viem'
import { z } from 'zod'

const address = z.string().regex(/^[1-9A-HJ-NP-Za-km-z]{32,44}$/)

export const configSchema = z.object({
  schedule: z.string(),
  rpcUrl: z.string(),
  secretId: z.string(),
  vault: address,
  bounty: address,
  threshold: z.string(),
})

type Config = z.infer<typeof configSchema>

type RpcError = { message?: string }
type RpcBody = { result?: unknown; error?: RpcError }
type BalanceResult = { value?: number | string }
type SimAccount = { lamports?: number | string } | null
type SimResult = {
  value?: {
    err?: unknown
    accounts?: SimAccount[] | null
  }
}

const BASE58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'

const pubkeyBytes = (value: string, label: string): Uint8Array => {
  let n = 0n
  for (const ch of value) {
    const digit = BASE58.indexOf(ch)
    if (digit < 0) {
      throw new Error(`${label} is not base58`)
    }
    n = n * 58n + BigInt(digit)
  }
  const out = new Uint8Array(32)
  for (let i = 31; i >= 0; i--) {
    out[i] = Number(n & 0xffn)
    n >>= 8n
  }
  if (n !== 0n) {
    throw new Error(`${label} is longer than 32 bytes`)
  }
  return out
}

const u64Bytes = (value: bigint, label: string): Uint8Array => {
  if (value < 0n || value >= 1n << 64n) {
    throw new Error(`${label} does not fit in u64`)
  }
  const out = new Uint8Array(8)
  new DataView(out.buffer).setBigUint64(0, value, true)
  return out
}

const asBig = (value: unknown, label: string): bigint => {
  if (typeof value === 'number' || typeof value === 'string' || typeof value === 'bigint') {
    return BigInt(value)
  }
  throw new Error(`${label} is not an integer`)
}

// The secret is `<payout>:<base64 transaction>`. Base58 and base64 do not contain `:`.
const parseSubmission = (secret: string): { payout: string; tx: string } => {
  const trimmed = secret.trim()
  const colon = trimmed.indexOf(':')
  if (colon <= 0 || colon !== trimmed.lastIndexOf(':')) {
    throw new Error('submission must be payout:transaction')
  }
  const payout = trimmed.slice(0, colon)
  const tx = trimmed.slice(colon + 1)
  if (!/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(payout)) {
    throw new Error('payout is not a base58 address')
  }
  if (!/^[A-Za-z0-9+/]+=*$/.test(tx) || tx.length < 80) {
    throw new Error('transaction is not base64')
  }
  return { payout, tx }
}

// Protobuf JSON encodes the HTTP body as base64. The simulateTransaction body carries
// the unpublished transaction, so `rpcUrl` sees the attack in plaintext.
const postJson = (runtime: TeeRuntime<Config>, method: string, params: unknown[]): unknown => {
  const payload = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params })
  const response = new cre.capabilities.HTTPClient()
    .sendRequest(runtime, {
      url: runtime.config.rpcUrl,
      method: 'POST',
      body: hexToBase64(stringToHex(payload)),
      multiHeaders: { 'content-type': { values: ['application/json'] } },
    })
    .result()

  if (!ok(response)) {
    throw new Error(`solana HTTP status ${response.statusCode} on ${method}`)
  }

  const parsed = json(response) as RpcBody
  if (parsed.error) {
    throw new Error(`solana ${method} failed: ${parsed.error.message ?? 'unknown'}`)
  }
  if (parsed.result === undefined || parsed.result === null) {
    throw new Error(`solana ${method} returned no result`)
  }
  return parsed.result
}

export const onCronTrigger = (runtime: TeeRuntime<Config>): string => {
  const config = runtime.config
  const threshold = BigInt(config.threshold)
  if (threshold <= 0n) {
    throw new Error('threshold must be positive')
  }

  // The unpublished transaction stays in the enclave. Do not log it or put it in the report.
  const secret = runtime.getSecret({ id: config.secretId }).result().value
  if (secret.length === 0) {
    throw new Error('attack transaction secret is empty')
  }
  const { payout, tx } = parseSubmission(secret)
  if (payout === config.vault || payout === config.bounty) {
    throw new Error('payout must not be the vault or the bounty')
  }

  const pre = asBig(
    (postJson(runtime, 'getBalance', [config.vault, { commitment: 'confirmed' }]) as BalanceResult).value,
    'pre balance',
  )
  const slot = asBig(postJson(runtime, 'getSlot', [{ commitment: 'confirmed' }]), 'slot')
  const simulated = postJson(runtime, 'simulateTransaction', [
    tx,
    {
      // Without signature checks a submission could sign as the vault admin or any
      // other privileged key. The whitehat must sign with keys they actually hold.
      encoding: 'base64',
      sigVerify: true,
      replaceRecentBlockhash: false,
      commitment: 'confirmed',
      accounts: {
        encoding: 'base64',
        addresses: [config.vault],
      },
    },
  ]) as SimResult
  if (simulated.value?.err) {
    throw new Error(`simulateTransaction failed: ${JSON.stringify(simulated.value.err)}`)
  }
  // Post balance is the simulated vault account, not a value returned by the transaction.
  const post = asBig(simulated.value?.accounts?.[0]?.lamports, 'post balance')
  if (pre < threshold || post >= threshold) {
    throw new Error(`predicate failed pre=${pre} post=${post}`)
  }

  // Layout `cre_bounty::on_report` decodes: pre, post, slot, threshold (u64 LE), payout, vault.
  const body = new Uint8Array(96)
  body.set(u64Bytes(pre, 'pre'), 0)
  body.set(u64Bytes(post, 'post'), 8)
  body.set(u64Bytes(slot, 'slot'), 16)
  body.set(u64Bytes(threshold, 'threshold'), 24)
  body.set(pubkeyBytes(payout, 'payout'), 32)
  body.set(pubkeyBytes(config.vault, 'vault'), 64)
  const report = bytesToHex(body)

  // usingTheDons() leaves the enclave. The signed report is the public journal, not the transaction.
  const donRuntime = runtime.usingTheDons()
  donRuntime
    .report({
      encodedPayload: hexToBase64(report),
      encoderName: 'solana',
      signingAlgo: 'ecdsa',
      hashingAlgo: 'keccak256',
    })
    .result()

  // Public fields only. script/test.sh parses these. Remove enclave logs before production.
  runtime.log(`SOLANA_JOURNAL pre=${pre} post=${post} slot=${slot} payout=${payout}`)
  return `SOLANA_REPORT=${report}`
}

export function initWorkflow(config: Config) {
  const cronTrigger = new cre.capabilities.CronCapability()
  return [
    cre.handlerInTee(cronTrigger.trigger({ schedule: config.schedule }), onCronTrigger, [
      { tee: 'nitro', regions: ['us-west-2'] },
    ]),
  ]
}
