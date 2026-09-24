// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CreatorConfig, ICreatorAccount} from "./Types.sol";
import {CreatorAccount} from "./CreatorAccount.sol";

/// @notice The single entry point a platform integrates against. A tip comes in
/// as stablecoin, the platform's cut leaves as stablecoin in the same
/// transaction, and the rest lands in the creator's own account.
/// This contract never holds anyone's balance between transactions.
contract TipRouter {
    using SafeERC20 for IERC20;

    struct Platform {
        address payout;
        uint16 feeBps;
        bool active;
    }

    uint16 public constant MAX_FEE_BPS = 5_000;

    address public owner;
    address public keeper;
    address public immutable implementation;

    address public immutable usdg;
    address public immutable venue;
    address public immutable signal;
    address public immutable treasury;

    mapping(bytes32 platformId => Platform) public platforms;
    mapping(bytes32 creatorId => address account) public accounts;
    mapping(bytes32 symbolId => address token) public tokenOf;

    uint256 public tipCount;

    event PlatformRegistered(bytes32 indexed platformId, address payout, uint16 feeBps);
    event PlatformDeactivated(bytes32 indexed platformId);
    event SymbolRegistered(bytes32 indexed symbolId, address token);
    event CreatorCreated(bytes32 indexed creatorId, address indexed account, address indexed owner);
    event Tipped(
        bytes32 indexed platformId,
        bytes32 indexed creatorId,
        address indexed fan,
        uint256 amount,
        uint256 fee,
        uint8 symbolChoice,
        bytes32 msgHash,
        uint256 tipId
    );
    event KeeperSet(address indexed keeper);
    event CreatorReassigned(bytes32 indexed creatorId, address indexed from, address indexed to);

    error NotOwner();
    error FeeTooHigh();
    error PlatformInactive();
    error CreatorUnknown();
    error CreatorExists();
    error ZeroAmount();
    error OwnerMustBeSender();
    error CreatorHasHistory();
    error NotOurAccount();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address usdg_, address venue_, address signal_, address treasury_, address keeper_) {
        owner = msg.sender;
        usdg = usdg_;
        venue = venue_;
        signal = signal_;
        treasury = treasury_;
        keeper = keeper_;
        implementation = address(new CreatorAccount());
        emit KeeperSet(keeper_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    // ------------------------------------------------------------- registry

    function registerPlatform(bytes32 platformId, address payout, uint16 feeBps) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        platforms[platformId] = Platform({payout: payout, feeBps: feeBps, active: true});
        emit PlatformRegistered(platformId, payout, feeBps);
    }

    function deactivatePlatform(bytes32 platformId) external onlyOwner {
        platforms[platformId].active = false;
        emit PlatformDeactivated(platformId);
    }

    function registerSymbol(bytes32 symbolId, address token) external onlyOwner {
        tokenOf[symbolId] = token;
        emit SymbolRegistered(symbolId, token);
    }

    // -------------------------------------------------------------- creators

    /// @notice Anyone may onboard, but only for themselves: you cannot create an
    /// account for a handle and hand it to someone else. Handles are still
    /// first-come-first-served, which is a real limit — see `reassignCreator`.
    function createCreator(bytes32 creatorId, CreatorConfig calldata cfg) external returns (address account) {
        if (cfg.owner != msg.sender) revert OwnerMustBeSender();
        if (accounts[creatorId] != address(0)) revert CreatorExists();
        account = Clones.clone(implementation);
        accounts[creatorId] = account;
        ICreatorAccount(account).initialize(address(this), cfg);
        emit CreatorCreated(creatorId, account, cfg.owner);
    }

    /// @notice Undo a squatted handle — and only a squatted one. Once a single
    /// tip has landed the binding is frozen, so this can never redirect money
    /// anyone has actually sent.
    /// @dev The replacement has to be an account this router made. Without that
    /// check the owner could point a handle at any address at all, and the next
    /// tip would be handed to something that is not a creator account.
    function reassignCreator(bytes32 creatorId, address newAccount) external onlyOwner {
        address current = accounts[creatorId];
        if (current == address(0)) revert CreatorUnknown();
        if (ICreatorAccount(current).tipCount() != 0) revert CreatorHasHistory();
        if (newAccount == address(0)) revert NotOurAccount();
        (bool ok, bytes memory data) =
            newAccount.staticcall(abi.encodeWithSelector(ICreatorAccount.router.selector));
        if (!ok || data.length != 32 || abi.decode(data, (address)) != address(this)) revert NotOurAccount();
        accounts[creatorId] = newAccount;
        emit CreatorReassigned(creatorId, current, newAccount);
    }

    // ------------------------------------------------------------------ tips

    function tip(bytes32 platformId, bytes32 creatorId, uint256 amount, bytes32 msgHash, uint8 symbolChoice)
        external
        returns (uint256 tipId)
    {
        return _tip(platformId, creatorId, amount, msgHash, symbolChoice);
    }

    /// @notice One-transaction tip for wallets that support EIP-2612.
    function tipWithPermit(
        bytes32 platformId,
        bytes32 creatorId,
        uint256 amount,
        bytes32 msgHash,
        uint8 symbolChoice,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 tipId) {
        try IERC20Permit(usdg).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        return _tip(platformId, creatorId, amount, msgHash, symbolChoice);
    }

    function _tip(bytes32 platformId, bytes32 creatorId, uint256 amount, bytes32 msgHash, uint8 symbolChoice)
        internal
        returns (uint256 tipId)
    {
        if (amount == 0) revert ZeroAmount();
        Platform memory p = platforms[platformId];
        if (!p.active) revert PlatformInactive();
        address account = accounts[creatorId];
        if (account == address(0)) revert CreatorUnknown();

        IERC20(usdg).safeTransferFrom(msg.sender, address(this), amount);

        uint256 fee = (amount * p.feeBps) / 10_000;
        if (fee != 0) IERC20(usdg).safeTransfer(p.payout, fee);

        uint256 rest = amount - fee;
        IERC20(usdg).safeTransfer(account, rest);
        ICreatorAccount(account).deposit(msg.sender, rest, symbolChoice);

        unchecked {
            tipId = ++tipCount;
        }
        emit Tipped(platformId, creatorId, msg.sender, amount, fee, symbolChoice, msgHash, tipId);
    }
}

