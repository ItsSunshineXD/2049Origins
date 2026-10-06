// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPausable} from "./IPausable.sol";

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @notice CRE consumer entry. `interfaceId` is `onReport` only; IERC165 is inherited.
interface IReceiver is IERC165 {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}

/// @title CreBounty
/// @notice Locks a bounty against one predicate: an unpublished transaction drives
///         `target`'s ETH balance from at least `threshold` to strictly below it.
///         A CRE report attests to that transition. The forwarder submits the report.
///         The payout address is inside the signed payload. There is no commit-reveal.
///
///         This contract does not check a zero-knowledge proof. It checks that the
///         caller is the configured forwarder and that the report matches the
///         protection. Trust in the report is trust in the TEE and the DON.
contract CreBounty is IReceiver {
    struct Protection {
        address registrant;
        address target;
        uint256 threshold;
        uint256 bounty;
        bool active;
        bool claimed;
    }

    /// @dev Report body. One memory pointer in `onReport`, so the decode does not
    ///      share a stack frame with the pause and the payout.
    struct Claim {
        uint256 chainId;
        address bounty;
        address target;
        uint64 blockNumber;
        bytes32 blockHash;
        uint256 threshold;
        uint256 preBalance;
        uint256 postBalance;
        address payout;
    }

    uint256 public constant BLOCKHASH_WINDOW = 256;
    bytes4 private constant RECEIVER_ID = IReceiver.onReport.selector;

    address public immutable forwarder;
    bytes32 public immutable workflowId;
    address public immutable workflowOwner;
    /// @dev Official CRE name encoding: first 10 ASCII hex chars of sha256(name).
    bytes10 public immutable workflowName;

    uint256 public nextId;
    mapping(uint256 => Protection) public protections;
    mapping(address => uint256) public targetToId;
    mapping(bytes32 => bool) public usedReports;

    error ZeroAddress();
    error EmptyBounty();
    error AlreadyProtected();
    error GuardianMismatch();
    error AlreadyPaused();
    error ThresholdRequired();
    error AlreadyAbnormal();
    error NotForwarder();
    error BadMetadata();
    error BadReport();
    error WorkflowMismatch();
    error NotActive();
    error PayoutRequired();
    error ReportUsed();
    error ChainMismatch();
    error BountyMismatch();
    error TargetMismatch();
    error PredicateMismatch();
    error BlockInFuture();
    error BlockTooOld();
    error BlockHashMismatch();
    error PredicateNotMet();
    error NotRegistrant();
    error PayoutFailed();

    event Registered(
        uint256 indexed id, address indexed target, address indexed registrant, uint256 bounty
    );
    event Reported(
        uint256 indexed id, address indexed payout, uint256 bounty, bytes32 reportDigest
    );
    event Cancelled(uint256 indexed id, address indexed registrant, uint256 bounty);

    /// @param workflowName_ The workflow name string. Stored as the bytes10 CRE encodes
    ///        on chain, not as the raw string. There is no admin setter: a new workflow
    ///        id means a new deployment.
    constructor(
        address forwarder_,
        bytes32 workflowId_,
        address workflowOwner_,
        string memory workflowName_
    ) {
        if (forwarder_ == address(0) || workflowOwner_ == address(0)) {
            revert ZeroAddress();
        }
        if (workflowId_ == bytes32(0)) revert WorkflowMismatch();
        if (bytes(workflowName_).length == 0) revert WorkflowMismatch();
        forwarder = forwarder_;
        workflowId = workflowId_;
        workflowOwner = workflowOwner_;
        workflowName = _encodeName(workflowName_);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == RECEIVER_ID || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Lock `msg.value` against `target`. The abnormal state is
    ///         `postBalance < threshold` after a pre-state that was still healthy.
    function register(address target, uint256 threshold) external payable returns (uint256 id) {
        if (msg.value == 0) revert EmptyBounty();
        if (targetToId[target] != 0) revert AlreadyProtected();
        if (IPausable(target).guardian() != address(this)) revert GuardianMismatch();
        if (IPausable(target).paused()) revert AlreadyPaused();
        if (threshold == 0) revert ThresholdRequired();
        if (target.balance < threshold) revert AlreadyAbnormal();

        id = ++nextId;
        protections[id] = Protection({
            registrant: msg.sender,
            target: target,
            threshold: threshold,
            bounty: msg.value,
            active: true,
            claimed: false
        });
        targetToId[target] = id;

        emit Registered(id, target, msg.sender, msg.value);
    }

    /// @notice Accept a DON report, pause `target`, and pay the address in the report.
    ///
    ///         `metadata` is packed, not ABI-encoded with a length prefix:
    ///         `bytes32 workflowId || bytes10 workflowName || address workflowOwner`,
    ///         then an optional trailing `bytes2` report id. Production
    ///         `KeystoneForwarder` forwards 64 bytes. Length 62 and 64 both pass.
    ///         The workflow name is the ASCII of the first 10 hex characters of
    ///         `sha256(name)`, not the name string itself.
    function onReport(bytes calldata metadata, bytes calldata report) external {
        if (msg.sender != forwarder) revert NotForwarder();
        (bytes32 id, bytes10 name, address owner) = _workflowOf(metadata);
        if (id != workflowId || name != workflowName || owner != workflowOwner) {
            revert WorkflowMismatch();
        }

        Claim memory claim = _claim(report);
        uint256 protectionId = targetToId[claim.target];
        Protection storage protection = protections[protectionId];
        if (!protection.active || protection.claimed || protection.target != claim.target) {
            revert NotActive();
        }
        if (claim.payout == address(0)) revert PayoutRequired();
        bytes32 reportDigest = keccak256(report);
        if (usedReports[reportDigest]) revert ReportUsed();
        if (claim.chainId != block.chainid) revert ChainMismatch();
        if (claim.bounty != address(this)) revert BountyMismatch();
        if (claim.threshold != protection.threshold) revert PredicateMismatch();
        if (claim.blockNumber >= block.number) revert BlockInFuture();
        if (block.number - claim.blockNumber > BLOCKHASH_WINDOW) revert BlockTooOld();
        bytes32 onchainHash = blockhash(claim.blockNumber);
        if (onchainHash == bytes32(0) || onchainHash != claim.blockHash) revert BlockHashMismatch();
        if (claim.preBalance < claim.threshold || claim.postBalance >= claim.threshold) {
            revert PredicateNotMet();
        }

        uint256 amount = protection.bounty;
        address payout = claim.payout;
        address target = claim.target;
        protection.claimed = true;
        protection.active = false;
        protection.bounty = 0;
        usedReports[reportDigest] = true;
        delete targetToId[target];

        IPausable(target).pause();

        (bool ok,) = payout.call{value: amount}("");
        if (!ok) revert PayoutFailed();

        emit Reported(protectionId, payout, amount, reportDigest);
    }

    /// @dev One word at a time. A single `abi.decode` of all nine fields overflows the stack.
    function _claim(bytes calldata report) internal pure returns (Claim memory claim) {
        if (report.length != 288) revert BadReport();
        claim.chainId = uint256(_word(report, 0));
        claim.bounty = address(uint160(uint256(_word(report, 1))));
        claim.target = address(uint160(uint256(_word(report, 2))));
        claim.blockNumber = uint64(uint256(_word(report, 3)));
        claim.blockHash = _word(report, 4);
        claim.threshold = uint256(_word(report, 5));
        claim.preBalance = uint256(_word(report, 6));
        claim.postBalance = uint256(_word(report, 7));
        claim.payout = address(uint160(uint256(_word(report, 8))));
    }

    function _word(bytes calldata report, uint256 index) private pure returns (bytes32 word) {
        assembly {
            word := calldataload(add(report.offset, mul(index, 32)))
        }
    }

    /// @notice Registrant withdraws an unclaimed bounty and drops the protection.
    function cancel(uint256 protectionId) external {
        Protection storage protection = protections[protectionId];
        if (protection.registrant != msg.sender) revert NotRegistrant();
        if (!protection.active || protection.claimed) revert NotActive();

        uint256 bounty = protection.bounty;
        protection.active = false;
        protection.bounty = 0;
        delete targetToId[protection.target];

        (bool ok,) = msg.sender.call{value: bounty}("");
        if (!ok) revert PayoutFailed();

        emit Cancelled(protectionId, msg.sender, bounty);
    }

    /// @dev First 10 ASCII hex characters of sha256(name), as bytes10.
    function _encodeName(string memory name) internal pure returns (bytes10 encoded) {
        bytes32 hash = sha256(bytes(name));
        bytes memory alphabet = "0123456789abcdef";
        bytes memory ascii10 = new bytes(10);
        for (uint256 i = 0; i < 5; i++) {
            uint8 b = uint8(hash[i]);
            ascii10[i * 2] = alphabet[b >> 4];
            ascii10[i * 2 + 1] = alphabet[b & 0x0f];
        }
        assembly {
            // bytes10 is the top 10 bytes. Mask off anything past the ASCII hex.
            encoded := and(mload(add(ascii10, 32)), shl(176, 0xffffffffffffffffffff))
        }
    }

    /// @dev Packed identity. A 64-byte production slice keeps an ignored `bytes2` at the end.
    function _workflowOf(bytes calldata metadata)
        internal
        pure
        returns (bytes32 id, bytes10 name, address owner)
    {
        if (metadata.length < 62) revert BadMetadata();
        assembly {
            id := calldataload(metadata.offset)
            // Name occupies the next 10 bytes. The following address must not remain in the word.
            name := and(calldataload(add(metadata.offset, 32)), shl(176, 0xffffffffffffffffffff))
            owner := shr(96, calldataload(add(metadata.offset, 42)))
        }
    }
}
