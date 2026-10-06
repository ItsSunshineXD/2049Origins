// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CreBounty} from "../src/CreBounty.sol";
import {VulnerableVault} from "../src/VulnerableVault.sol";

/// @notice Deploys the vault and `CreBounty` only. The attacker is never deployed.
///         `onReport` is sent later by `script/cre-demo.sh` from the local forwarder.
contract CreDemo is Script {
    /// Anvil dev account 1. The CRE report names this payout.
    address internal constant PAYOUT = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    /// Anvil dev account 2. Local stand-in for KeystoneForwarder.
    address internal constant FORWARDER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    uint256 internal constant VAULT_DEPOSIT = 10 ether;
    uint256 internal constant BOUNTY_ETH = 10 ether;
    uint256 internal constant THRESHOLD = 1 ether;

    function run() external {
        bytes32 workflowId = vm.envBytes32("WORKFLOW_ID");
        string memory workflowName = vm.envString("WORKFLOW_NAME");
        address workflowOwner = vm.envAddress("WORKFLOW_OWNER");

        vm.startBroadcast();
        address admin = msg.sender;
        uint64 nonce = vm.getNonce(admin);
        address predictedBounty = vm.computeCreateAddress(admin, nonce + 1);

        VulnerableVault vault = new VulnerableVault(admin, predictedBounty);
        CreBounty bounty = new CreBounty(FORWARDER, workflowId, workflowOwner, workflowName);
        require(address(bounty) == predictedBounty, "bounty address mismatch");

        vault.deposit{value: VAULT_DEPOSIT}();
        uint256 id = bounty.register{value: BOUNTY_ETH}(address(vault), THRESHOLD);
        vm.stopBroadcast();

        console2.log(string.concat("DEMO_VAULT=", vm.toString(address(vault))));
        console2.log(string.concat("DEMO_BOUNTY=", vm.toString(address(bounty))));
        console2.log(string.concat("DEMO_PROTECTION=", vm.toString(id)));
        console2.log(string.concat("DEMO_PAYOUT=", vm.toString(PAYOUT)));
        console2.log(string.concat("DEMO_FORWARDER=", vm.toString(FORWARDER)));
    }
}
