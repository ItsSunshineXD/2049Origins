//! Local demo vault. Depositors pool lamports and withdraw their own credit.
//! The pool also lends idle lamports as a single-transaction flash loan:
//! `flash_borrow` sends lamports out and checks, through the Instructions
//! sysvar, that a `flash_end` for this program comes later in the same
//! transaction. `flash_end` requires the vault balance to be back where it was.
//!
//! Solana does not let a program be re-entered through another program, so the
//! loan cannot call back into the borrower. The borrower runs its own
//! instructions between `flash_borrow` and `flash_end` instead.
use solana_program::{
    account_info::{next_account_info, AccountInfo},
    entrypoint,
    entrypoint::ProgramResult,
    program::invoke,
    program::invoke_signed,
    program_error::ProgramError,
    pubkey::Pubkey,
    rent::Rent,
    system_instruction,
    sysvar::{
        instructions::{load_current_index_checked, load_instruction_at_checked},
        Sysvar,
    },
};

include!("id.rs");

entrypoint!(process_instruction);

/// 0 paused, 1 bump, 2..34 guardian, 34..66 admin,
/// 66..74 balance `flash_end` must see, 74 open-loan flag.
const VAULT_SPACE: usize = 75;
const POSITION_SPACE: usize = 8;
const FLASH_REQUIRED: usize = 66;
const FLASH_OPEN: usize = 74;
const IX_FLASH_END: u8 = 5;

fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    data: &[u8],
) -> ProgramResult {
    let (disc, rest) = data.split_first().ok_or(ProgramError::InvalidInstructionData)?;
    match disc {
        0 => initialize(program_id, accounts, rest),
        1 => deposit(program_id, accounts, rest),
        2 => pause(program_id, accounts),
        3 => withdraw(program_id, accounts, rest),
        4 => flash_borrow(program_id, accounts, rest),
        5 => flash_end(program_id, accounts, rest),
        _ => Err(ProgramError::InvalidInstructionData),
    }
}

fn vault_pda(program_id: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[b"vault"], program_id)
}

fn position_pda(program_id: &Pubkey, user: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[b"pos", user.as_ref()], program_id)
}

fn initialize(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if data.len() != 64 {
        return Err(ProgramError::InvalidInstructionData);
    }
    let guardian = Pubkey::try_from(&data[0..32]).map_err(|_| ProgramError::InvalidInstructionData)?;
    let admin = Pubkey::try_from(&data[32..64]).map_err(|_| ProgramError::InvalidInstructionData)?;
    let iter = &mut accounts.iter();
    let payer = next_account_info(iter)?;
    let vault = next_account_info(iter)?;
    let system = next_account_info(iter)?;
    if !payer.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    let (pda, bump) = vault_pda(program_id);
    if vault.key != &pda {
        return Err(ProgramError::InvalidSeeds);
    }
    let rent = Rent::get()?.minimum_balance(VAULT_SPACE);
    let ix = system_instruction::create_account(payer.key, vault.key, rent, VAULT_SPACE as u64, program_id);
    invoke_signed(
        &ix,
        &[payer.clone(), vault.clone(), system.clone()],
        &[&[b"vault", &[bump]]],
    )?;
    let mut body = vault.try_borrow_mut_data()?;
    body[0] = 0;
    body[1] = bump;
    body[2..34].copy_from_slice(guardian.as_ref());
    body[34..66].copy_from_slice(admin.as_ref());
    Ok(())
}

/// Signer pays `amount` lamports into the vault and increases their own position.
fn deposit(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if data.len() != 8 {
        return Err(ProgramError::InvalidInstructionData);
    }
    let amount = u64::from_le_bytes(data.try_into().unwrap());
    if amount == 0 {
        return Err(ProgramError::InvalidInstructionData);
    }
    let iter = &mut accounts.iter();
    let user = next_account_info(iter)?;
    let vault = next_account_info(iter)?;
    let position = next_account_info(iter)?;
    let system = next_account_info(iter)?;
    if !user.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    let (vault_key, _) = vault_pda(program_id);
    if vault.key != &vault_key || vault.owner != program_id || vault.data_len() != VAULT_SPACE {
        return Err(ProgramError::InvalidAccountData);
    }
    if vault.try_borrow_data()?[0] != 0 {
        return Err(ProgramError::Custom(1));
    }
    let (pda, bump) = position_pda(program_id, user.key);
    if position.key != &pda {
        return Err(ProgramError::InvalidSeeds);
    }
    if position.data_len() == 0 {
        let rent = Rent::get()?.minimum_balance(POSITION_SPACE);
        let create = system_instruction::create_account(
            user.key,
            position.key,
            rent,
            POSITION_SPACE as u64,
            program_id,
        );
        invoke_signed(
            &create,
            &[user.clone(), position.clone(), system.clone()],
            &[&[b"pos", user.key.as_ref(), &[bump]]],
        )?;
    } else if position.owner != program_id || position.data_len() != POSITION_SPACE {
        return Err(ProgramError::InvalidAccountData);
    }
    invoke(
        &system_instruction::transfer(user.key, vault.key, amount),
        &[user.clone(), vault.clone(), system.clone()],
    )?;
    let mut body = position.try_borrow_mut_data()?;
    let credit = u64::from_le_bytes(body[0..8].try_into().unwrap());
    let next = credit.checked_add(amount).ok_or(ProgramError::InvalidInstructionData)?;
    body[0..8].copy_from_slice(&next.to_le_bytes());
    Ok(())
}

/// Pays the signer's whole credit and clears it. Refuses while a flash loan is open.
///
/// Account order: 0 vault, 1 user (signer), 2 position.
fn withdraw(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if !data.is_empty() {
        return Err(ProgramError::InvalidInstructionData);
    }
    let iter = &mut accounts.iter();
    let vault = next_account_info(iter)?;
    let user = next_account_info(iter)?;
    let position = next_account_info(iter)?;
    if !user.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    let (vault_key, _) = vault_pda(program_id);
    if vault.key != &vault_key || vault.owner != program_id || vault.data_len() != VAULT_SPACE {
        return Err(ProgramError::InvalidAccountData);
    }
    if user.key == vault.key {
        return Err(ProgramError::InvalidArgument);
    }
    let (pda, _) = position_pda(program_id, user.key);
    if position.key != &pda || position.owner != program_id || position.data_len() != POSITION_SPACE {
        return Err(ProgramError::InvalidAccountData);
    }
    {
        let body = vault.try_borrow_data()?;
        if body[0] != 0 {
            return Err(ProgramError::Custom(1));
        }
        if body[FLASH_OPEN] != 0 {
            return Err(ProgramError::Custom(3));
        }
    }
    let credit = {
        let body = position.try_borrow_data()?;
        u64::from_le_bytes(body[0..8].try_into().unwrap())
    };
    if credit == 0 {
        return Err(ProgramError::InsufficientFunds);
    }
    position.try_borrow_mut_data()?[0..8].copy_from_slice(&0u64.to_le_bytes());
    {
        let mut vault_lamports = vault.try_borrow_mut_lamports()?;
        let mut user_lamports = user.try_borrow_mut_lamports()?;
        **vault_lamports = vault_lamports.checked_sub(credit).ok_or(ProgramError::InsufficientFunds)?;
        **user_lamports = user_lamports.checked_add(credit).ok_or(ProgramError::InsufficientFunds)?;
    }
    Ok(())
}

/// Lends `amount` idle lamports until `flash_end` later in the same transaction.
///
/// Account order: 0 vault, 1 borrower (signer), 2 Instructions sysvar.
fn flash_borrow(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if data.len() != 8 {
        return Err(ProgramError::InvalidInstructionData);
    }
    let amount = u64::from_le_bytes(data.try_into().unwrap());
    let iter = &mut accounts.iter();
    let vault = next_account_info(iter)?;
    let borrower = next_account_info(iter)?;
    let instructions = next_account_info(iter)?;
    if !borrower.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    let (vault_key, _) = vault_pda(program_id);
    if vault.key != &vault_key || vault.owner != program_id || vault.data_len() != VAULT_SPACE {
        return Err(ProgramError::InvalidAccountData);
    }
    {
        let body = vault.try_borrow_data()?;
        if body[0] != 0 {
            return Err(ProgramError::Custom(1));
        }
        if body[FLASH_OPEN] != 0 {
            return Err(ProgramError::Custom(3));
        }
    }
    let idle = vault.lamports().saturating_sub(Rent::get()?.minimum_balance(VAULT_SPACE));
    if amount == 0 || amount > idle {
        return Err(ProgramError::InsufficientFunds);
    }
    if !flash_end_follows(program_id, instructions)? {
        return Err(ProgramError::Custom(4));
    }

    let required = vault.lamports();
    {
        let mut body = vault.try_borrow_mut_data()?;
        body[FLASH_REQUIRED..FLASH_REQUIRED + 8].copy_from_slice(&required.to_le_bytes());
        body[FLASH_OPEN] = 1;
    }
    {
        let mut vault_lamports = vault.try_borrow_mut_lamports()?;
        let mut borrower_lamports = borrower.try_borrow_mut_lamports()?;
        **vault_lamports -= amount;
        **borrower_lamports = borrower_lamports.checked_add(amount).ok_or(ProgramError::InsufficientFunds)?;
    }
    Ok(())
}

/// Closes the open loan once the vault holds at least what it held at `flash_borrow`.
///
/// Account order: 0 vault.
fn flash_end(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if !data.is_empty() {
        return Err(ProgramError::InvalidInstructionData);
    }
    let vault = next_account_info(&mut accounts.iter())?;
    let (vault_key, _) = vault_pda(program_id);
    if vault.key != &vault_key || vault.owner != program_id || vault.data_len() != VAULT_SPACE {
        return Err(ProgramError::InvalidAccountData);
    }
    let lamports = vault.lamports();
    let mut body = vault.try_borrow_mut_data()?;
    if body[FLASH_OPEN] == 0 {
        return Err(ProgramError::Custom(5));
    }
    let required = u64::from_le_bytes(body[FLASH_REQUIRED..FLASH_REQUIRED + 8].try_into().unwrap());
    if lamports < required {
        return Err(ProgramError::Custom(6));
    }
    body[FLASH_REQUIRED..FLASH_REQUIRED + 8].copy_from_slice(&0u64.to_le_bytes());
    body[FLASH_OPEN] = 0;
    Ok(())
}

fn flash_end_follows(program_id: &Pubkey, instructions: &AccountInfo) -> Result<bool, ProgramError> {
    if instructions.key != &solana_program::sysvar::instructions::id() {
        return Err(ProgramError::InvalidArgument);
    }
    let mut index = load_current_index_checked(instructions)? as usize + 1;
    while let Ok(ix) = load_instruction_at_checked(index, instructions) {
        if ix.program_id == *program_id && ix.data.first() == Some(&IX_FLASH_END) {
            return Ok(true);
        }
        index += 1;
    }
    Ok(false)
}

fn pause(program_id: &Pubkey, accounts: &[AccountInfo]) -> ProgramResult {
    let iter = &mut accounts.iter();
    let vault = next_account_info(iter)?;
    let guardian = next_account_info(iter)?;
    if vault.owner != program_id || vault.data_len() != VAULT_SPACE {
        return Err(ProgramError::InvalidAccountData);
    }
    if !guardian.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    let data = vault.try_borrow_data()?;
    let stored = Pubkey::try_from(&data[2..34]).map_err(|_| ProgramError::InvalidAccountData)?;
    if guardian.key != &stored {
        return Err(ProgramError::Custom(2));
    }
    drop(data);
    vault.try_borrow_mut_data()?[0] = 1;
    Ok(())
}
