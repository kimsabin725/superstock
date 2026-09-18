// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TapeSignal} from "../src/TapeSignal.sol";
import {TipRouter} from "../src/TipRouter.sol";
import {CreatorAccount} from "../src/CreatorAccount.sol";
import {CreatorConfig, Position} from "../src/Types.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @dev The first end-to-end tip on X Layer testnet: a fan pays stablecoin, the
/// platform takes its cut in stablecoin, and the creator ends up holding stock.
contract FirstTip is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        uint256 keeperPk = vm.envUint("KEEPER_PK");
        address me = vm.addr(pk);

        string memory j = vm.readFile("deployments.1952.json");
        TipRouter router = TipRouter(vm.parseJsonAddress(j, ".TipRouter"));
        TapeSignal signal = TapeSignal(vm.parseJsonAddress(j, ".TapeSignal"));
        MockERC20 usdg = MockERC20(vm.parseJsonAddress(j, ".USDG"));

        bytes32 NVDAX = keccak256("NVDAx");
        bytes32 SPYX = keccak256("SPYx");
        bytes32 CREATOR = keccak256("@indiemusician");
        bytes32 PLATFORM = keccak256("orbit");

        // 1. keeper publishes the tape: both names open, price fresh
        vm.startBroadcast(keeperPk);
        bytes32[] memory ids = new bytes32[](2);
        TapeSignal.Signal[] memory sigs = new TapeSignal.Signal[](2);
        ids[0] = NVDAX;
        ids[1] = SPYX;
        for (uint256 i; i < 2; ++i) {
            sigs[i] = TapeSignal.Signal({
                session: 0,
                haltCode: 0,
                caEffectiveAt: 0,
                priceUpdatedAt: uint40(block.timestamp),
                observedAt: uint40(block.timestamp)
            });
        }
        signal.setBatch(ids, sigs);
        vm.stopBroadcast();

        vm.startBroadcast(pk);

        // 2. creator onboards: half NVDAx, half SPYx, locked a year
        address account = router.accounts(CREATOR);
        if (account == address(0)) {
            bytes32[] memory syms = new bytes32[](2);
            uint16[] memory w = new uint16[](2);
            syms[0] = NVDAX;
            syms[1] = SPYX;
            w[0] = 5000;
            w[1] = 5000;
            account = router.createCreator(
                CREATOR,
                CreatorConfig({
                    owner: me,
                    symbols: syms,
                    weightsBps: w,
                    lockUntil: uint40(block.timestamp + 365 days),
                    receiveUsdgOnly: false,
                    sweepToTreasury: true
                })
            );
        }

        // 3. a fan tips $20
        usdg.approve(address(router), type(uint256).max);
        router.tip(PLATFORM, CREATOR, 20e6, keccak256(bytes("thanks for the set")), 0);

        // 4. the keeper's batch turns the cash into stock
        CreatorAccount(account).executeBuys();

        vm.stopBroadcast();

        (Position[] memory pos, uint256 pending, uint256 treasuryBal,) = CreatorAccount(account).statement();
        console.log("creator account:", account);
        console.log("pending USDG   :", pending);
        console.log("treasury bal   :", treasuryBal);
        for (uint256 i; i < pos.length; ++i) {
            console.log("  holding", pos[i].token, pos[i].balance);
        }
    }
}
