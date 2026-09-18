// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TapeSignal} from "../src/TapeSignal.sol";
import {TipRouter} from "../src/TipRouter.sol";
import {CreatorAccount} from "../src/CreatorAccount.sol";
import {CreatorConfig} from "../src/Types.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAMM} from "../src/mocks/MockAMM.sol";
import {MockTreasury} from "../src/mocks/MockTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract Base is Test {
    MockERC20 usdg;
    MockERC20 nvda;
    MockERC20 spy;
    TapeSignal signal;
    MockAMM amm;
    MockTreasury treasury;
    TipRouter router;

    address deployer = address(this);
    address keeper = makeAddr("keeper");
    address platformPayout = makeAddr("platformPayout");
    address creator = makeAddr("creator");
    address fan = makeAddr("fan");

    bytes32 constant NVDAX = keccak256("NVDAx");
    bytes32 constant SPYX = keccak256("SPYx");
    bytes32 constant PLATFORM = keccak256("orbit");
    bytes32 constant DIRECT = keccak256("direct");
    bytes32 constant CREATOR_ID = keccak256("@indiemusician");

    uint256 constant T0 = 1_780_000_000;

    function setUp() public virtual {
        vm.warp(T0);

        usdg = new MockERC20("Mock USDG", "mUSDG", 6);
        nvda = new MockERC20("Mock NVDAx", "mNVDAx", 18);
        spy = new MockERC20("Mock SPYx", "mSPYx", 18);

        signal = new TapeSignal(keeper);
        amm = new MockAMM(address(usdg), keeper);
        treasury = new MockTreasury(IERC20(address(usdg)));
        router = new TipRouter(address(usdg), address(amm), address(signal), address(treasury), keeper);

        router.registerSymbol(NVDAX, address(nvda));
        router.registerSymbol(SPYX, address(spy));
        router.registerPlatform(PLATFORM, platformPayout, 1000); // 10%
        router.registerPlatform(DIRECT, platformPayout, 0);

        vm.startPrank(keeper);
        amm.setPrice(address(nvda), 180e8);
        amm.setPrice(address(spy), 560e8);
        vm.stopPrank();

        _setOpen(NVDAX);
        _setOpen(SPYX);

        usdg.mint(fan, 10_000e6);
        vm.prank(fan);
        usdg.approve(address(router), type(uint256).max);
    }

    // ------------------------------------------------------------- helpers

    function _setSignal(bytes32 sym, uint8 session, uint16 halt, uint40 caAt, uint40 priceAt, uint40 observedAt)
        internal
    {
        bytes32[] memory ids = new bytes32[](1);
        TapeSignal.Signal[] memory sigs = new TapeSignal.Signal[](1);
        ids[0] = sym;
        sigs[0] = TapeSignal.Signal({
            session: session,
            haltCode: halt,
            caEffectiveAt: caAt,
            priceUpdatedAt: priceAt,
            observedAt: observedAt
        });
        vm.prank(keeper);
        signal.setBatch(ids, sigs);
    }

    function _setOpen(bytes32 sym) internal {
        _setSignal(sym, 0, 0, 0, uint40(vm.getBlockTimestamp()), uint40(vm.getBlockTimestamp()));
    }

    function _setClosed(bytes32 sym) internal {
        _setSignal(sym, 2, 0, 0, uint40(vm.getBlockTimestamp()), uint40(vm.getBlockTimestamp()));
    }

    function _defaultConfig() internal view returns (CreatorConfig memory cfg) {
        bytes32[] memory syms = new bytes32[](2);
        uint16[] memory w = new uint16[](2);
        syms[0] = NVDAX;
        syms[1] = SPYX;
        w[0] = 5000;
        w[1] = 5000;
        cfg = CreatorConfig({
            owner: creator,
            symbols: syms,
            weightsBps: w,
            lockUntil: uint40(vm.getBlockTimestamp() + 365 days),
            receiveUsdgOnly: false,
            sweepToTreasury: false
        });
    }

    function _newCreator(CreatorConfig memory cfg) internal returns (CreatorAccount) {
        return _newCreator(CREATOR_ID, cfg);
    }

    /// @dev Onboarding is done by the creator themselves, which the router enforces.
    function _newCreator(bytes32 creatorId, CreatorConfig memory cfg) internal returns (CreatorAccount) {
        vm.prank(cfg.owner);
        return CreatorAccount(router.createCreator(creatorId, cfg));
    }

    function _tip(uint256 amount, uint8 choice) internal {
        vm.prank(fan);
        router.tip(PLATFORM, CREATOR_ID, amount, keccak256("gg"), choice);
    }
}
