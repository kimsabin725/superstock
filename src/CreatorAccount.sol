// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CreatorConfig, Position, ISwapVenue, ITapeSignal, ITipRouter} from "./Types.sol";

/// @notice One self-custody account per creator, deployed as an EIP-1167 clone.
/// Tips land here as cash and turn into the creator's chosen stocks when the
/// tape says the market is open. Nothing here can move the creator's money
/// except the creator; the keeper can only trigger buys the rules already allow.
contract CreatorAccount {
    using SafeERC20 for IERC20;

    address public router;
    address public owner;

    IERC20 public usdg;
    ISwapVenue public venue;
    ITapeSignal public signal;
    IERC4626 public treasury;

    bytes32[] public symbols;
    uint16[] public weightsBps;
    uint40 public lockUntil;
    bool public receiveUsdgOnly;
    bool public sweepToTreasury;

    /// @dev cash waiting to be split across `symbols` by weight
    uint256 public pendingUsdg;
    /// @dev cash a fan pinned to one symbol
    mapping(bytes32 symbolId => uint256) public pinnedPending;
    uint256 public pinnedTotal;

    uint256 public sweptPrincipal;
    uint256 public yieldEarned;
    mapping(bytes32 symbolId => uint256) public dividendUsd;

    uint256 public tipCount;
    uint256 public totalTipped;

    event Deposited(address indexed fan, uint256 amount, uint8 symbolChoice, uint256 tipCount);
    event Bought(bytes32 indexed symbolId, uint256 usdgIn, uint256 tokensOut, uint256 priceRefE8);
    event Held(bytes32 indexed symbolId, uint256 amount, uint16 reason);
    event Swept(uint256 amount, uint256 shares);
    event Unswept(uint256 amount, uint256 interest);
    event Withdrawn(address indexed token, uint256 amount);
    event DividendObserved(bytes32 indexed symbolId, uint256 oldBal, uint256 newBal, uint256 netUsd);
    event ConfigSet(uint40 lockUntil, bool receiveUsdgOnly, bool sweepToTreasury);
    event PinnedReleased(bytes32 indexed symbolId, uint256 amount);

    error AlreadyInitialized();
    error NotRouter();
    error NotOwner();
    error NotKeeper();
    error BadWeights();
    error BadChoice();
    error LockNotExpired();
    error LockCannotShorten();
    error InsufficientBalance();
    error SweepDisabled();
    error WithdrawTreasuryAsCash();

    modifier onlyRouter() {
        if (msg.sender != router) revert NotRouter();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function initialize(address router_, CreatorConfig calldata cfg) external {
        if (router != address(0)) revert AlreadyInitialized();
        router = router_;
        usdg = IERC20(ITipRouter(router_).usdg());
        venue = ISwapVenue(ITipRouter(router_).venue());
        signal = ITapeSignal(ITipRouter(router_).signal());
        treasury = IERC4626(ITipRouter(router_).treasury());
        owner = cfg.owner;
        _setPortfolio(cfg.symbols, cfg.weightsBps);
        lockUntil = cfg.lockUntil;
        receiveUsdgOnly = cfg.receiveUsdgOnly;
        sweepToTreasury = cfg.sweepToTreasury;
        emit ConfigSet(cfg.lockUntil, cfg.receiveUsdgOnly, cfg.sweepToTreasury);
    }

    // ---------------------------------------------------------------- config

    /// @dev `owner` is deliberately not read here: the account's owner is fixed
    /// at creation, so a config update can never hand the account to someone else.
    function setConfig(CreatorConfig calldata cfg) external onlyOwner {
        if (cfg.lockUntil < lockUntil) revert LockCannotShorten();
        _releasePinned(cfg.symbols);
        _setPortfolio(cfg.symbols, cfg.weightsBps);
        lockUntil = cfg.lockUntil;
        receiveUsdgOnly = cfg.receiveUsdgOnly;
        sweepToTreasury = cfg.sweepToTreasury;
        emit ConfigSet(cfg.lockUntil, cfg.receiveUsdgOnly, cfg.sweepToTreasury);
    }

    /// @dev Cash a fan pinned to a symbol the creator is dropping would otherwise
    /// be unreachable by executeBuys and invisible to the statement. It goes back
    /// into the weighted pool instead of being stranded.
    function _releasePinned(bytes32[] calldata next) internal {
        for (uint256 i; i < symbols.length; ++i) {
            bytes32 sym = symbols[i];
            uint256 pinned = pinnedPending[sym];
            if (pinned == 0) continue;
            bool kept;
            for (uint256 j; j < next.length; ++j) {
                if (next[j] == sym) {
                    kept = true;
                    break;
                }
            }
            if (kept) continue;
            pinnedPending[sym] = 0;
            pinnedTotal -= pinned;
            pendingUsdg += pinned;
            emit PinnedReleased(sym, pinned);
        }
    }

    function _setPortfolio(bytes32[] calldata symbols_, uint16[] calldata weights_) internal {
        if (symbols_.length == 0 || symbols_.length != weights_.length) revert BadWeights();
        uint256 sum;
        for (uint256 i; i < weights_.length; ++i) {
            sum += weights_[i];
        }
        if (sum != 10_000) revert BadWeights();
        symbols = symbols_;
        weightsBps = weights_;
    }

    // ----------------------------------------------------------------- tips

    /// @dev The router has already transferred `amount` to this contract.
    function deposit(address fan, uint256 amount, uint8 symbolChoice) external onlyRouter {
        if (symbolChoice == 0) {
            pendingUsdg += amount;
        } else {
            uint256 idx = symbolChoice - 1;
            if (idx >= symbols.length) revert BadChoice();
            pinnedPending[symbols[idx]] += amount;
            pinnedTotal += amount;
        }
        unchecked {
            ++tipCount;
            totalTipped += amount;
        }
        emit Deposited(fan, amount, symbolChoice, tipCount);
    }

    // ----------------------------------------------------------------- buys

    /// @notice Anyone may call. Buys only what the tape currently allows;
    /// everything else stays as cash and is tried again later.
    function executeBuys() external {
        if (receiveUsdgOnly) return;
        _unsweep();

        uint256 base = pendingUsdg;
        uint256 n = symbols.length;
        for (uint256 i; i < n; ++i) {
            bytes32 sym = symbols[i];
            uint256 fromWeighted = (base * weightsBps[i]) / 10_000;
            uint256 pinned = pinnedPending[sym];
            uint256 amount = fromWeighted + pinned;
            if (amount == 0) continue;

            address token = ITipRouter(router).tokenOf(sym);
            if (token == address(0)) {
                emit Held(sym, amount, 402); // nothing to buy it with
                continue;
            }

            (bool allow, uint16 reason) = signal.check(sym);
            if (!allow) {
                emit Held(sym, amount, reason);
                continue;
            }

            pendingUsdg -= fromWeighted;
            if (pinned != 0) {
                pinnedPending[sym] = 0;
                pinnedTotal -= pinned;
            }

            usdg.forceApprove(address(venue), amount);
            uint256 out = venue.swapExactUsdgForStock(token, amount, 0, address(this));
            emit Bought(sym, amount, out, 0);
        }
    }

    // -------------------------------------------------------------- treasury

    /// @notice Park idle cash in tokenized treasuries while it waits for the open.
    function sweepIdle() external {
        if (!sweepToTreasury) revert SweepDisabled();
        uint256 idle = usdg.balanceOf(address(this));
        if (idle == 0) return;
        usdg.forceApprove(address(treasury), idle);
        uint256 shares = treasury.deposit(idle, address(this));
        sweptPrincipal += idle;
        emit Swept(idle, shares);
    }

    function _unsweep() internal {
        uint256 shares = IERC20(address(treasury)).balanceOf(address(this));
        if (shares == 0) return;
        uint256 got = treasury.redeem(shares, address(this), address(this));
        uint256 interest = got > sweptPrincipal ? got - sweptPrincipal : 0;
        sweptPrincipal = 0;
        if (interest != 0) {
            yieldEarned += interest;
            pendingUsdg += interest; // yield gets invested alongside the tips
        }
        emit Unswept(got, interest);
    }

    // ------------------------------------------------------------ withdrawal

    function withdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(usdg)) {
            _unsweep();
            if (usdg.balanceOf(address(this)) < amount) revert InsufficientBalance();
            _debitPending(amount);
            usdg.safeTransfer(owner, amount);
        } else {
            // the lock guards stock; treasury shares are cash in another shape
            if (token == address(treasury)) revert WithdrawTreasuryAsCash();
            if (block.timestamp < lockUntil) revert LockNotExpired();
            IERC20(token).safeTransfer(owner, amount);
        }
        emit Withdrawn(token, amount);
    }

    /// @dev Cash leaving the account has to come off the books too: weighted
    /// bucket first, then whatever fans pinned, in portfolio order.
    function _debitPending(uint256 amount) internal {
        uint256 fromWeighted = amount > pendingUsdg ? pendingUsdg : amount;
        pendingUsdg -= fromWeighted;
        uint256 rest = amount - fromWeighted;
        for (uint256 i; rest != 0 && i < symbols.length; ++i) {
            bytes32 sym = symbols[i];
            uint256 take = pinnedPending[sym] > rest ? rest : pinnedPending[sym];
            if (take == 0) continue;
            pinnedPending[sym] -= take;
            pinnedTotal -= take;
            rest -= take;
        }
    }

    // ------------------------------------------------------------- dividends

    /// @notice Informational only — xStocks rebase on their own. The keeper
    /// records what it saw so the statement can show it.
    function recordDividend(bytes32 symbolId, uint256 oldBal, uint256 newBal, uint256 netUsd) external {
        if (msg.sender != ITipRouter(router).keeper()) revert NotKeeper();
        dividendUsd[symbolId] += netUsd;
        emit DividendObserved(symbolId, oldBal, newBal, netUsd);
    }

    // ------------------------------------------------------------- statement

    function statement()
        external
        view
        returns (Position[] memory positions, uint256 pending, uint256 treasuryBal, uint256 yield_)
    {
        uint256 n = symbols.length;
        positions = new Position[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 sym = symbols[i];
            address token = ITipRouter(router).tokenOf(sym);
            positions[i] = Position({
                symbolId: sym,
                token: token,
                balance: token == address(0) ? 0 : IERC20(token).balanceOf(address(this)),
                pinnedPending: pinnedPending[sym],
                dividendUsd: dividendUsd[sym]
            });
        }
        pending = pendingUsdg + pinnedTotal;
        uint256 shares = IERC20(address(treasury)).balanceOf(address(this));
        treasuryBal = shares == 0 ? 0 : treasury.previewRedeem(shares);
        yield_ = yieldEarned;
    }

    function portfolio() external view returns (bytes32[] memory, uint16[] memory) {
        return (symbols, weightsBps);
    }
}
