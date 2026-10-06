// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pause hook the bounty contract is pre-authorized to call.
interface IPausable {
    function pause() external;
    function paused() external view returns (bool);
    function guardian() external view returns (address);
}
