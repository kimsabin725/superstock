// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {CreatorAccount} from "../src/CreatorAccount.sol";
import {CreatorConfig, Position} from "../src/Types.sol";

contract CreatorAccountTest is Base {
    CreatorAccount account;

    function setUp() public override {
        super.setUp();
        account = _newCreator(_defaultConfig());
    }

    // ------------------------------------------------------------ buying

    function test_WeightedBuyWhenMarketOpen() public {
        _tip(20e6, 0); // 18 USDG after the platform cut, split 50/50
        account.executeBuys();

        // 9 USDG at $180 less a 10bp spread
        uint256 half = 9e6;
        uint256 expectNvda = ((half * 1e8 * 1e18) / (uint256(180e8) * 1e6)) * 9990 / 10_000;
        uint256 expectSpy = ((half * 1e8 * 1e18) / (uint256(560e8) * 1e6)) * 9990 / 10_000;
        assertEq(nvda.balanceOf(address(account)), expectNvda, "NVDAx");
        assertEq(spy.balanceOf(address(account)), expectSpy, "SPYx");
        assertEq(account.pendingUsdg(), 0, "nothing left waiting");
    }

    function test_ClosedMarketHoldsCashThenBuysOnReopen() public {
        _setClosed(NVDAX);
        _setClosed(SPYX);
        _tip(20e6, 0);

        account.executeBuys();
        assertEq(nvda.balanceOf(address(account)), 0, "no buy while closed");
        assertEq(account.pendingUsdg(), 18e6, "cash still on the books");
        assertEq(usdg.balanceOf(address(account)), 18e6, "cash still in the account");

        vm.warp(vm.getBlockTimestamp() + 2 days);
        _setOpen(NVDAX);
        _setOpen(SPYX);
        account.executeBuys();
        assertGt(nvda.balanceOf(address(account)), 0, "bought on reopen");
        assertEq(account.pendingUsdg(), 0);
    }

    function test_HaltHoldsOnlyTheHaltedSymbol() public {
        _setSignal(NVDAX, 0, 201, 0, uint40(vm.getBlockTimestamp()), uint40(vm.getBlockTimestamp())); // LUDP volatility halt
        _tip(20e6, 0);
        account.executeBuys();

        assertEq(nvda.balanceOf(address(account)), 0, "halted symbol held");
        assertGt(spy.balanceOf(address(account)), 0, "other symbol traded");
        assertEq(account.pendingUsdg(), 9e6, "the halted half stays as cash");
    }

    function test_CorporateActionWindowHolds() public {
        _setSignal(NVDAX, 0, 0, uint40(vm.getBlockTimestamp() + 600), uint40(vm.getBlockTimestamp()), uint40(vm.getBlockTimestamp()));
        _tip(20e6, 0);
        account.executeBuys();
        assertEq(nvda.balanceOf(address(account)), 0, "held inside the CA window");

        vm.warp(vm.getBlockTimestamp() + 3 hours);
        _setSignal(NVDAX, 0, 0, uint40(T0 + 600), uint40(vm.getBlockTimestamp()), uint40(vm.getBlockTimestamp()));
        account.executeBuys();
        assertGt(nvda.balanceOf(address(account)), 0, "bought once the window passed");
    }

    function test_StaleKeeperHoldsEverything() public {
        _tip(20e6, 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours); // keeper stopped writing
        account.executeBuys();
        assertEq(nvda.balanceOf(address(account)), 0);
        assertEq(spy.balanceOf(address(account)), 0);
        assertEq(account.pendingUsdg(), 18e6, "fail-safe keeps the cash");
    }

    function test_StalePriceHolds() public {
        // signal fresh, price not
        _setSignal(NVDAX, 0, 0, 0, uint40(vm.getBlockTimestamp() - 1 hours), uint40(vm.getBlockTimestamp()));
        _tip(20e6, 0);
        account.executeBuys();
        assertEq(nvda.balanceOf(address(account)), 0);
        assertGt(spy.balanceOf(address(account)), 0);
    }

    function test_HeldEventCarriesTheReason() public {
        _setClosed(NVDAX);
        _tip(20e6, 0);
        vm.expectEmit(true, false, false, true, address(account));
        emit CreatorAccount.Held(NVDAX, 9e6, 100);
        account.executeBuys();
    }

    function test_ExtendedSessionStillBuys() public {
        _setSignal(NVDAX, 1, 0, 0, uint40(vm.getBlockTimestamp()), uint40(vm.getBlockTimestamp())); // pre/after hours
        _tip(20e6, 0);
        account.executeBuys();
        assertGt(nvda.balanceOf(address(account)), 0);
    }

    function test_HkexLunchHolds() public {
        _setSignal(NVDAX, 3, 0, 0, uint40(vm.getBlockTimestamp()), uint40(vm.getBlockTimestamp()));
        _tip(20e6, 0);
        account.executeBuys();
        assertEq(nvda.balanceOf(address(account)), 0);
        assertEq(account.pendingUsdg(), 9e6);
    }

    // --------------------------------------------------------- fan choice

    function test_PinnedTipBuysOnlyThatSymbol() public {
        _tip(20e6, 1); // fan pinned NVDAx
        assertEq(account.pinnedPending(NVDAX), 18e6);
        assertEq(account.pendingUsdg(), 0);

        account.executeBuys();
        assertGt(nvda.balanceOf(address(account)), 0);
        assertEq(spy.balanceOf(address(account)), 0, "SPYx untouched");
        assertEq(account.pinnedPending(NVDAX), 0);
    }

    function test_PinnedChoiceOutOfRangeReverts() public {
        vm.prank(fan);
        vm.expectRevert(CreatorAccount.BadChoice.selector);
        router.tip(PLATFORM, CREATOR_ID, 20e6, bytes32(0), 9);
    }

    // ------------------------------------------------------------- lock

    function test_LockBlocksStockWithdrawalAndAllowsCash() public {
        _tip(20e6, 0);
        account.executeBuys();

        vm.prank(creator);
        vm.expectRevert(CreatorAccount.LockNotExpired.selector);
        account.withdraw(address(nvda), 1);

        _tip(10e6, 0); // fresh cash, still pending
        vm.prank(creator);
        account.withdraw(address(usdg), 9e6); // cash is never locked
        assertEq(usdg.balanceOf(creator), 9e6);
    }

    function test_StockWithdrawableAfterLock() public {
        _tip(20e6, 0);
        account.executeBuys();
        uint256 bal = nvda.balanceOf(address(account));

        vm.warp(vm.getBlockTimestamp() + 366 days);
        vm.prank(creator);
        account.withdraw(address(nvda), bal);
        assertEq(nvda.balanceOf(creator), bal);
    }

    function test_OnlyOwnerWithdraws() public {
        _tip(20e6, 0);
        vm.prank(fan);
        vm.expectRevert(CreatorAccount.NotOwner.selector);
        account.withdraw(address(usdg), 1e6);
    }

    function test_CashWithdrawalComesOffTheBooks() public {
        _tip(20e6, 0);
        vm.prank(creator);
        account.withdraw(address(usdg), 18e6);
        assertEq(account.pendingUsdg(), 0, "pending cleared with the cash");
    }

    function test_LockCannotBeShortened() public {
        CreatorConfig memory cfg = _defaultConfig();
        cfg.lockUntil = uint40(vm.getBlockTimestamp() + 1 days);
        vm.prank(creator);
        vm.expectRevert(CreatorAccount.LockCannotShorten.selector);
        account.setConfig(cfg);
    }

    function test_LockCanBeExtended() public {
        CreatorConfig memory cfg = _defaultConfig();
        cfg.lockUntil = uint40(vm.getBlockTimestamp() + 730 days);
        vm.prank(creator);
        account.setConfig(cfg);
        assertEq(account.lockUntil(), uint40(vm.getBlockTimestamp() + 730 days));
    }

    function test_WeightsMustSumToFull() public {
        CreatorConfig memory cfg = _defaultConfig();
        cfg.weightsBps[0] = 4000;
        vm.prank(creator);
        vm.expectRevert(CreatorAccount.BadWeights.selector);
        account.setConfig(cfg);
    }

    // --------------------------------------------------------- treasury

    function test_IdleCashEarnsTreasuryYieldAndComesBackForTheBuy() public {
        CreatorConfig memory cfg = _defaultConfig();
        cfg.sweepToTreasury = true;
        CreatorAccount acct = CreatorAccount(router.createCreator(keccak256("@saver"), cfg));

        _setClosed(NVDAX);
        _setClosed(SPYX);
        vm.prank(fan);
        router.tip(PLATFORM, keccak256("@saver"), 1_000e6, bytes32(0), 0);

        acct.sweepIdle();
        assertEq(usdg.balanceOf(address(acct)), 0, "cash is parked");
        assertGt(treasury.balanceOf(address(acct)), 0, "vault shares held");

        vm.warp(vm.getBlockTimestamp() + 365 days);
        _setOpen(NVDAX);
        _setOpen(SPYX);
        acct.executeBuys();

        // 4.5%/yr on 900 USDG ~= 40.5 USDG, invested alongside the tips
        assertApproxEqRel(acct.yieldEarned(), 40.5e6, 0.01e18, "a year of treasury yield");
        assertEq(treasury.balanceOf(address(acct)), 0, "pulled back out for the buy");
        assertGt(nvda.balanceOf(address(acct)), 0);
    }

    function test_SweepRevertsWhenDisabled() public {
        vm.expectRevert(CreatorAccount.SweepDisabled.selector);
        account.sweepIdle();
    }

    // ------------------------------------------------------- cash-only mode

    function test_CashOnlyCreatorNeverBuys() public {
        CreatorConfig memory cfg = _defaultConfig();
        cfg.receiveUsdgOnly = true;
        CreatorAccount acct = CreatorAccount(router.createCreator(keccak256("@cash"), cfg));

        vm.prank(fan);
        router.tip(PLATFORM, keccak256("@cash"), 20e6, bytes32(0), 0);
        acct.executeBuys();

        assertEq(nvda.balanceOf(address(acct)), 0);
        vm.prank(creator);
        acct.withdraw(address(usdg), 18e6);
        assertEq(usdg.balanceOf(creator), 18e6);
    }

    // ---------------------------------------------------------- dividends

    function test_KeeperRecordsDividend() public {
        vm.prank(keeper);
        account.recordDividend(NVDAX, 100e18, 101e18, 12_340_000);
        assertEq(account.dividendUsd(NVDAX), 12_340_000);
    }

    function test_OnlyKeeperRecordsDividend() public {
        vm.prank(fan);
        vm.expectRevert(CreatorAccount.NotKeeper.selector);
        account.recordDividend(NVDAX, 100e18, 101e18, 1);
    }

    // ---------------------------------------------------------- statement

    function test_StatementShowsTheWholeAccount() public {
        _tip(20e6, 0);
        account.executeBuys();
        _tip(10e6, 1);

        (Position[] memory pos, uint256 pending, uint256 treasuryBal, uint256 yield_) = account.statement();
        assertEq(pos.length, 2);
        assertEq(pos[0].symbolId, NVDAX);
        assertGt(pos[0].balance, 0);
        assertEq(pos[0].pinnedPending, 9e6);
        assertEq(pending, 9e6);
        assertEq(treasuryBal, 0);
        assertEq(yield_, 0);
    }

    // ------------------------------------------------- portfolio changes

    function test_DroppedSymbolDoesNotStrandPinnedCash() public {
        _tip(20e6, 2); // fan pinned SPYx
        assertEq(account.pinnedPending(SPYX), 18e6);

        // creator drops SPYx and goes all-in on NVDAx
        bytes32[] memory syms = new bytes32[](1);
        uint16[] memory w = new uint16[](1);
        syms[0] = NVDAX;
        w[0] = 10000;
        CreatorConfig memory cfg = _defaultConfig();
        cfg.symbols = syms;
        cfg.weightsBps = w;
        vm.prank(creator);
        account.setConfig(cfg);

        assertEq(account.pinnedPending(SPYX), 0, "pin released");
        assertEq(account.pendingUsdg(), 18e6, "cash went back to the pool");

        (, uint256 pending,,) = account.statement();
        assertEq(pending, 18e6, "statement still adds up");
        assertEq(pending, usdg.balanceOf(address(account)), "books match the balance");

        account.executeBuys();
        assertGt(nvda.balanceOf(address(account)), 0, "and it is still spendable");
    }

    function test_UnregisteredSymbolIsHeldNotReverted() public {
        bytes32 ghost = keccak256("GHOSTx");
        bytes32[] memory syms = new bytes32[](2);
        uint16[] memory w = new uint16[](2);
        syms[0] = NVDAX;
        syms[1] = ghost;
        w[0] = 5000;
        w[1] = 5000;
        CreatorConfig memory cfg = _defaultConfig();
        cfg.symbols = syms;
        cfg.weightsBps = w;
        CreatorAccount acct = CreatorAccount(router.createCreator(keccak256("@typo"), cfg));

        // a signal exists for the ghost symbol, but no token was ever registered
        _setOpen(ghost);
        vm.prank(fan);
        router.tip(PLATFORM, keccak256("@typo"), 20e6, bytes32(0), 0);

        acct.executeBuys(); // must not revert
        assertGt(nvda.balanceOf(address(acct)), 0, "the good half still bought");
        assertEq(acct.pendingUsdg(), 9e6, "the bad half is just held");
    }

    function test_TreasurySharesAreNotLockedStock() public {
        CreatorConfig memory cfg = _defaultConfig();
        cfg.sweepToTreasury = true;
        CreatorAccount acct = CreatorAccount(router.createCreator(keccak256("@parked"), cfg));
        _setClosed(NVDAX);
        _setClosed(SPYX);
        vm.prank(fan);
        router.tip(PLATFORM, keccak256("@parked"), 100e6, bytes32(0), 0);
        acct.sweepIdle();

        vm.prank(creator);
        vm.expectRevert(CreatorAccount.WithdrawTreasuryAsCash.selector);
        acct.withdraw(address(treasury), 1);

        // the cash route works and pulls the position back out
        vm.prank(creator);
        acct.withdraw(address(usdg), 90e6);
        assertEq(usdg.balanceOf(creator), 90e6);
    }
}