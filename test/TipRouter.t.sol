// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {TipRouter} from "../src/TipRouter.sol";
import {CreatorAccount} from "../src/CreatorAccount.sol";
import {CreatorConfig} from "../src/Types.sol";

contract TipRouterTest is Base {
    CreatorAccount account;

    function setUp() public override {
        super.setUp();
        account = _newCreator(_defaultConfig());
    }

    function test_TipSplitsFeeAndPrincipal() public {
        _tip(20e6, 0);
        assertEq(usdg.balanceOf(platformPayout), 2e6, "platform cut");
        assertEq(usdg.balanceOf(address(account)), 18e6, "creator share");
        assertEq(account.pendingUsdg(), 18e6, "booked as pending");
        assertEq(account.tipCount(), 1);
        assertEq(account.totalTipped(), 18e6);
    }

    function test_FeeRoundsDownToPlatform() public {
        // 10% of 1_000_005 wei-units = 100_000.5 -> 100_000
        _tip(1_000_005, 0);
        assertEq(usdg.balanceOf(platformPayout), 100_000);
        assertEq(usdg.balanceOf(address(account)), 900_005);
        assertEq(usdg.balanceOf(address(router)), 0, "router keeps nothing");
    }

    function test_DirectPlatformTakesNoFee() public {
        vm.prank(fan);
        router.tip(DIRECT, CREATOR_ID, 20e6, bytes32(0), 0);
        assertEq(usdg.balanceOf(platformPayout), 0);
        assertEq(usdg.balanceOf(address(account)), 20e6);
    }

    function test_RouterNeverHoldsBalance() public {
        _tip(20e6, 0);
        _tip(5e6, 1);
        assertEq(usdg.balanceOf(address(router)), 0);
    }

    function test_UnregisteredPlatformReverts() public {
        vm.prank(fan);
        vm.expectRevert(TipRouter.PlatformInactive.selector);
        router.tip(keccak256("nope"), CREATOR_ID, 20e6, bytes32(0), 0);
    }

    function test_DeactivatedPlatformReverts() public {
        router.deactivatePlatform(PLATFORM);
        vm.prank(fan);
        vm.expectRevert(TipRouter.PlatformInactive.selector);
        router.tip(PLATFORM, CREATOR_ID, 20e6, bytes32(0), 0);
    }

    function test_UnknownCreatorReverts() public {
        vm.prank(fan);
        vm.expectRevert(TipRouter.CreatorUnknown.selector);
        router.tip(PLATFORM, keccak256("@ghost"), 20e6, bytes32(0), 0);
    }

    function test_ZeroAmountReverts() public {
        vm.prank(fan);
        vm.expectRevert(TipRouter.ZeroAmount.selector);
        router.tip(PLATFORM, CREATOR_ID, 0, bytes32(0), 0);
    }

    function test_FeeAboveCapRejected() public {
        vm.expectRevert(TipRouter.FeeTooHigh.selector);
        router.registerPlatform(keccak256("greedy"), platformPayout, 5001);
    }

    function test_FeeAtCapAccepted() public {
        router.registerPlatform(keccak256("atcap"), platformPayout, 5000);
        (, uint16 feeBps,) = router.platforms(keccak256("atcap"));
        assertEq(feeBps, 5000);
    }

    function test_OnlyOwnerRegisters() public {
        vm.prank(fan);
        vm.expectRevert(TipRouter.NotOwner.selector);
        router.registerPlatform(keccak256("x"), fan, 100);
    }

    function test_DuplicateCreatorReverts() public {
        vm.expectRevert(TipRouter.CreatorExists.selector);
        _newCreator(_defaultConfig());
    }

    function test_CreatorAccountsAreDistinctClones() public {
        CreatorConfig memory cfg = _defaultConfig();
        cfg.owner = fan;
        address other = address(_newCreator(keccak256("@other"), cfg));
        assertTrue(other != address(account));
        assertEq(CreatorAccount(other).owner(), fan);
        assertEq(account.owner(), creator);
    }

    function test_TipWithPermitIsOneTransaction() public {
        uint256 pk = 0xA11CE;
        address signer = vm.addr(pk);
        usdg.mint(signer, 100e6);

        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(router),
                20e6,
                usdg.nonces(signer),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdg.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vm.prank(signer);
        router.tipWithPermit(PLATFORM, CREATOR_ID, 20e6, bytes32(0), 0, deadline, v, r, s);

        assertEq(usdg.balanceOf(address(account)), 18e6);
        assertEq(usdg.balanceOf(signer), 80e6);
    }

    function test_TipEmitsCardPayload() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit TipRouter.Tipped(PLATFORM, CREATOR_ID, fan, 20e6, 2e6, 0, keccak256("gg"), 1);
        _tip(20e6, 0);
    }

    // ----------------------------------------------------- handle ownership

    function test_CannotOnboardOnSomeoneElsesBehalf() public {
        CreatorConfig memory cfg = _defaultConfig();
        cfg.owner = creator;
        vm.prank(fan);
        vm.expectRevert(TipRouter.OwnerMustBeSender.selector);
        router.createCreator(keccak256("@victim"), cfg);
    }

    function test_SquattedHandleCanBeReassignedBeforeAnyTip() public {
        CreatorConfig memory squatter = _defaultConfig();
        squatter.owner = fan;
        address bad = address(_newCreator(keccak256("@contested"), squatter));

        CreatorConfig memory real = _defaultConfig();
        address good = address(_newCreator(keccak256("@contested-real"), real));

        router.reassignCreator(keccak256("@contested"), good);
        assertEq(router.accounts(keccak256("@contested")), good);
        assertTrue(bad != good);
    }

    function test_ReassignIsFrozenOnceMoneyHasMoved() public {
        CreatorConfig memory squatter = _defaultConfig();
        squatter.owner = fan;
        _newCreator(keccak256("@contested"), squatter);

        vm.prank(fan);
        router.tip(PLATFORM, keccak256("@contested"), 1e6, bytes32(0), 0);

        vm.expectRevert(TipRouter.CreatorHasHistory.selector);
        router.reassignCreator(keccak256("@contested"), address(0xdead));
    }

    function test_ReassignOnlyToAnAccountThisRouterMade() public {
        CreatorConfig memory squatter = _defaultConfig();
        squatter.owner = fan;
        _newCreator(keccak256("@contested"), squatter);

        // a plain address, a contract that is not one of ours, and nothing at all
        vm.expectRevert(TipRouter.NotOurAccount.selector);
        router.reassignCreator(keccak256("@contested"), address(0xdead));

        vm.expectRevert(TipRouter.NotOurAccount.selector);
        router.reassignCreator(keccak256("@contested"), address(usdg));

        vm.expectRevert(TipRouter.NotOurAccount.selector);
        router.reassignCreator(keccak256("@contested"), address(0));
    }

    function test_OnlyRouterOwnerReassigns() public {
        CreatorConfig memory cfg = _defaultConfig();
        cfg.owner = fan;
        _newCreator(keccak256("@x"), cfg);
        vm.prank(fan);
        vm.expectRevert(TipRouter.NotOwner.selector);
        router.reassignCreator(keccak256("@x"), address(1));
    }
}