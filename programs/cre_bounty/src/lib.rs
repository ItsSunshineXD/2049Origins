//! Pays a bounty when a forwarder submits a simulated drain, then pauses the vault.
//! The report is trusted as a TEE attestation. This program does not re-execute the
//! unpublished transaction and does not check a zero-knowledge proof.
use solana_program::{
    account_info::{next_account_info, AccountInfo},
    entrypoint,
    entrypoint::ProgramResult,
    instruction::{AccountMeta, Instruction},
    program::invoke_signed,
    program_error::ProgramError,
    pubkey::Pubkey,
    rent::Rent,
    system_instruction,
    sysvar::{clock::Clock, Sysvar},
};

include!("id.rs");

entrypoint!(process_instruction);

/// 0..32 admin, 32..64 forwarder, 64..96 vault, 96..104 threshold, 104..112 amount,
/// 112 active, 113 claimed, 114 bump, 115..123 unix time after which `cancel` may run.
const BOUNTY_SPACE: usize = 123;
const SLOT_WINDOW: u64 = 150;
/// A pending report stays claimable this long after the admin asks to cancel, so the
/// admin cannot front-run `on_report` with `cancel`.
const CANCEL_DELAY: i64 = 7 * 24 * 60 * 60;
const CANCEL_AFTER: usize = 115;

fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    data: &[u8],
) -> ProgramResult {
    let (disc, rest) = data.split_first().ok_or(ProgramError::InvalidInstructionData)?;
    match disc {
        0 => initialize(program_id, accounts, rest),
        1 => register(program_id, accounts, rest),
        2 => on_report(program_id, accounts, rest),
        3 => request_cancel(program_id, accounts),
        4 => cancel(program_id, accounts),
        _ => Err(ProgramError::InvalidInstructionData),
    }
}

fn initialize(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if data.len() != 64 {
        return Err(ProgramError::InvalidInstructionData);
    }
    let forwarder = Pubkey::try_from(&data[0..32]).map_err(|_| ProgramError::InvalidInstructionData)?;
    let admin = Pubkey::try_from(&data[32..64]).map_err(|_| ProgramError::InvalidInstructionData)?;
    let iter = &mut accounts.iter();
    let payer = next_account_info(iter)?;
    let bounty = next_account_info(iter)?;
    let system = next_account_info(iter)?;
    if !payer.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    let (pda, bump) = Pubkey::find_program_address(&[b"bounty"], program_id);
    if bounty.key != &pda {
        return Err(ProgramError::InvalidSeeds);
    }
    let rent = Rent::get()?.minimum_balance(BOUNTY_SPACE);
    let ix = system_instruction::create_account(
        payer.key,
        bounty.key,
        rent,
        BOUNTY_SPACE as u64,
        program_id,
    );
    invoke_signed(
        &ix,
        &[payer.clone(), bounty.clone(), system.clone()],
        &[&[b"bounty", &[bump]]],
    )?;
    let mut body = bounty.try_borrow_mut_data()?;
    body[0..32].copy_from_slice(admin.as_ref());
    body[32..64].copy_from_slice(forwarder.as_ref());
    body[114] = bump;
    Ok(())
}

fn register(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if data.len() != 16 {
        return Err(ProgramError::InvalidInstructionData);
    }
    let threshold = u64::from_le_bytes(data[0..8].try_into().unwrap());
    let amount = u64::from_le_bytes(data[8..16].try_into().unwrap());
    if threshold == 0 || amount == 0 {
        return Err(ProgramError::InvalidInstructionData);
    }
    let iter = &mut accounts.iter();
    let registrant = next_account_info(iter)?;
    let bounty = next_account_info(iter)?;
    let vault = next_account_info(iter)?;
    let system = next_account_info(iter)?;
    if !registrant.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    let (pda, bump) = Pubkey::find_program_address(&[b"bounty"], program_id);
    if bounty.key != &pda || bounty.owner != program_id || bounty.data_len() != BOUNTY_SPACE {
        return Err(ProgramError::InvalidSeeds);
    }
    {
        let body = bounty.try_borrow_data()?;
        if registrant.key.as_ref() != &body[0..32] {
            return Err(ProgramError::Custom(8));
        }
        if body[112] != 0 {
            return Err(ProgramError::Custom(3));
        }
    }
    // Vault layout: 0 paused, 2..34 guardian. The pause CPI in `on_report` needs this PDA.
    {
        let state = vault.try_borrow_data()?;
        if state.len() < 34 || state[0] != 0 || &state[2..34] != bounty.key.as_ref() {
            return Err(ProgramError::Custom(9));
        }
    }
    if vault.lamports() < threshold {
        return Err(ProgramError::Custom(10));
    }
    solana_program::program::invoke(
        &system_instruction::transfer(registrant.key, bounty.key, amount),
        &[registrant.clone(), bounty.clone(), system.clone()],
    )?;
    let mut body = bounty.try_borrow_mut_data()?;
    body[64..96].copy_from_slice(vault.key.as_ref());
    body[96..104].copy_from_slice(&threshold.to_le_bytes());
    body[104..112].copy_from_slice(&amount.to_le_bytes());
    body[112] = 1;
    body[113] = 0;
    body[114] = bump;
    body[CANCEL_AFTER..CANCEL_AFTER + 8].copy_from_slice(&0i64.to_le_bytes());
    Ok(())
}

/// Admin signer and bounty PDA, with an active, unclaimed protection.
fn admin_bounty<'a, 'b>(
    program_id: &Pubkey,
    accounts: &'a [AccountInfo<'b>],
) -> Result<(&'a AccountInfo<'b>, &'a AccountInfo<'b>), ProgramError> {
    let iter = &mut accounts.iter();
    let admin = next_account_info(iter)?;
    let bounty = next_account_info(iter)?;
    if !admin.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    let (pda, _) = Pubkey::find_program_address(&[b"bounty"], program_id);
    if bounty.key != &pda || bounty.owner != program_id || bounty.data_len() != BOUNTY_SPACE {
        return Err(ProgramError::InvalidAccountData);
    }
    let body = bounty.try_borrow_data()?;
    if admin.key.as_ref() != &body[0..32] {
        return Err(ProgramError::Custom(8));
    }
    if body[112] == 0 || body[113] != 0 {
        return Err(ProgramError::Custom(5));
    }
    Ok((admin, bounty))
}

/// Starts the cancel delay. The bounty stays claimable until `cancel` runs.
///
/// Account order: 0 admin (signer), 1 bounty.
fn request_cancel(program_id: &Pubkey, accounts: &[AccountInfo]) -> ProgramResult {
    let (_, bounty) = admin_bounty(program_id, accounts)?;
    let mut body = bounty.try_borrow_mut_data()?;
    let pending = i64::from_le_bytes(body[CANCEL_AFTER..CANCEL_AFTER + 8].try_into().unwrap());
    if pending != 0 {
        return Err(ProgramError::Custom(11));
    }
    let after = Clock::get()?.unix_timestamp + CANCEL_DELAY;
    body[CANCEL_AFTER..CANCEL_AFTER + 8].copy_from_slice(&after.to_le_bytes());
    Ok(())
}

/// Returns the unclaimed bounty to the admin, no earlier than `CANCEL_DELAY` after
/// `request_cancel`.
///
/// Account order: 0 admin (signer, writable), 1 bounty.
fn cancel(program_id: &Pubkey, accounts: &[AccountInfo]) -> ProgramResult {
    let (admin, bounty) = admin_bounty(program_id, accounts)?;
    let amount = {
        let body = bounty.try_borrow_data()?;
        let after = i64::from_le_bytes(body[CANCEL_AFTER..CANCEL_AFTER + 8].try_into().unwrap());
        if after == 0 {
            return Err(ProgramError::Custom(12));
        }
        if Clock::get()?.unix_timestamp < after {
            return Err(ProgramError::Custom(13));
        }
        u64::from_le_bytes(body[104..112].try_into().unwrap())
    };
    {
        let mut body = bounty.try_borrow_mut_data()?;
        body[104..112].copy_from_slice(&0u64.to_le_bytes());
        body[112] = 0;
        body[CANCEL_AFTER..CANCEL_AFTER + 8].copy_from_slice(&0i64.to_le_bytes());
    }
    **bounty.try_borrow_mut_lamports()? =
        bounty.lamports().checked_sub(amount).ok_or(ProgramError::InsufficientFunds)?;
    **admin.try_borrow_mut_lamports()? =
        admin.lamports().checked_add(amount).ok_or(ProgramError::InsufficientFunds)?;
    Ok(())
}

fn on_report(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if data.len() != 96 {
        return Err(ProgramError::InvalidInstructionData);
    }
    let pre = u64::from_le_bytes(data[0..8].try_into().unwrap());
    let post = u64::from_le_bytes(data[8..16].try_into().unwrap());
    let slot = u64::from_le_bytes(data[16..24].try_into().unwrap());
    let threshold = u64::from_le_bytes(data[24..32].try_into().unwrap());
    let payout = Pubkey::try_from(&data[32..64]).map_err(|_| ProgramError::InvalidInstructionData)?;
    let reported_vault =
        Pubkey::try_from(&data[64..96]).map_err(|_| ProgramError::InvalidInstructionData)?;

    let iter = &mut accounts.iter();
    let forwarder = next_account_info(iter)?;
    let bounty = next_account_info(iter)?;
    let vault = next_account_info(iter)?;
    let payout_account = next_account_info(iter)?;
    let vault_program = next_account_info(iter)?;
    if !forwarder.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    let (pda, bump) = Pubkey::find_program_address(&[b"bounty"], program_id);
    if bounty.key != &pda || bounty.owner != program_id || bounty.data_len() != BOUNTY_SPACE {
        return Err(ProgramError::InvalidAccountData);
    }
    let body = bounty.try_borrow_data()?;
    let stored_forwarder = Pubkey::try_from(&body[32..64]).map_err(|_| ProgramError::InvalidAccountData)?;
    let stored_vault = Pubkey::try_from(&body[64..96]).map_err(|_| ProgramError::InvalidAccountData)?;
    let stored_threshold = u64::from_le_bytes(body[96..104].try_into().unwrap());
    let bounty_amount = u64::from_le_bytes(body[104..112].try_into().unwrap());
    if forwarder.key != &stored_forwarder {
        return Err(ProgramError::Custom(4));
    }
    if body[112] == 0 || body[113] != 0 {
        return Err(ProgramError::Custom(5));
    }
    if vault.key != &stored_vault || reported_vault != stored_vault || payout_account.key != &payout {
        return Err(ProgramError::InvalidArgument);
    }
    if threshold != stored_threshold || pre < threshold || post >= threshold {
        return Err(ProgramError::Custom(6));
    }
    let now = Clock::get()?.slot;
    if slot > now || now - slot > SLOT_WINDOW {
        return Err(ProgramError::Custom(7));
    }
    if !vault_program.executable || vault.owner != vault_program.key {
        return Err(ProgramError::IncorrectProgramId);
    }
    if payout_account.key == bounty.key || payout_account.key == vault.key {
        return Err(ProgramError::InvalidArgument);
    }
    drop(body);

    let pause = Instruction {
        program_id: *vault_program.key,
        accounts: vec![
            AccountMeta::new(*vault.key, false),
            AccountMeta::new_readonly(*bounty.key, true),
        ],
        data: vec![2],
    };
    invoke_signed(
        &pause,
        &[vault.clone(), bounty.clone()],
        &[&[b"bounty", &[bump]]],
    )?;

    **bounty.try_borrow_mut_lamports()? = bounty
        .lamports()
        .checked_sub(bounty_amount)
        .ok_or(ProgramError::InsufficientFunds)?;
    **payout_account.try_borrow_mut_lamports()? = payout_account
        .lamports()
        .checked_add(bounty_amount)
        .ok_or(ProgramError::InsufficientFunds)?;
    bounty.try_borrow_mut_data()?[113] = 1;
    bounty.try_borrow_mut_data()?[112] = 0;
    Ok(())
}
