// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title VulnerableVault
/// @notice Local demo vault. `withdraw` sends ETH before it updates balances.
///         This contract is the only place the reentrancy bug exists. Do not deploy it
///         with real funds.
contract VulnerableVault {
    mapping(address => uint256) public balanceOf;
    uint256 public liabilities;

    address public immutable admin;
    address public immutable guardian;
    bool public paused;

    error ZeroAddress();
    error Paused();
    error NotGuardian();
    error NotAdmin();
    error InsufficientBalance();
    error TransferFailed();

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    constructor(address admin_, address guardian_) {
        if (admin_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        admin = admin_;
        guardian = guardian_;
    }

    function deposit() external payable whenNotPaused {
        balanceOf[msg.sender] += msg.value;
        liabilities += msg.value;
    }

    /// @dev Sends the full credit before clearing it. A callback can call `withdraw` again
    ///      while `balanceOf` is still non-zero and drain other depositors' ETH.
    function withdraw() external whenNotPaused {
        uint256 amount = balanceOf[msg.sender];
        if (amount == 0) revert InsufficientBalance();
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        balanceOf[msg.sender] = 0;
        liabilities -= amount;
    }

    function pause() external {
        if (msg.sender != guardian) revert NotGuardian();
        paused = true;
    }

    function unpause() external {
        if (msg.sender != admin) revert NotAdmin();
        paused = false;
    }
}
