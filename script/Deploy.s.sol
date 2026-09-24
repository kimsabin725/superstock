// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TapeSignal} from "../src/TapeSignal.sol";
import {TipRouter} from "../src/TipRouter.sol";
import {CreatorAccount} from "../src/CreatorAccount.sol";
import {CreatorConfig} from "../src/Types.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAMM} from "../src/mocks/MockAMM.sol";
import {MockTreasury} from "../src/mocks/MockTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Testnet deployment. On X Layer mainnet the three mocks are replaced by
/// the real USDG, the real xStocks wrappers and the real Uniswap v3 pools;
/// nothing else about the system changes.
contract Deploy is Script {
    string[5] TICKERS = ["NVDAx", "TSLAx", "SPYx", "AAPLx", "COINx"];
    uint256[5] PRICES_E8 = [uint256(180e8), 420e8, 560e8, 232e8, 310e8];

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address keeper = vm.envAddress("KEEPER_ADDR");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);

        MockERC20 usdg = new MockERC20("Mock USDG", "mUSDG", 6);
        TapeSignal signal = new TapeSignal();
        // Seed the venue ourselves, then hand the keys to the keeper.
        MockAMM amm = new MockAMM(address(usdg), me);
        MockTreasury treasury = new MockTreasury(IERC20(address(usdg)));
        TipRouter router =
            new TipRouter(address(usdg), address(amm), address(signal), address(treasury), keeper);

        address[] memory stocks = new address[](5);
        for (uint256 i; i < 5; ++i) {
            MockERC20 t = new MockERC20(string.concat("Mock ", TICKERS[i]), string.concat("m", TICKERS[i]), 18);
            stocks[i] = address(t);
            router.registerSymbol(keccak256(bytes(TICKERS[i])), address(t));
            amm.setPrice(address(t), PRICES_E8[i]);
        }

        signal.setKeeper(keeper);
        amm.setKeeper(keeper);

        // Demo platforms: one that takes a cut, one for a bare profile link.
        router.registerPlatform(keccak256("orbit"), me, 1000);
        router.registerPlatform(keccak256("twitchlike"), me, 500);
        router.registerPlatform(keccak256("direct"), me, 0);

        // Seed the venue and the deployer so the first tip can go through.
        usdg.mint(me, 100_000e6);

        vm.stopBroadcast();

        _writeDeployment(address(usdg), address(signal), address(amm), address(treasury), address(router), stocks, me, keeper);

        console.log("USDG     ", address(usdg));
        console.log("TapeSignal", address(signal));
        console.log("MockAMM  ", address(amm));
        console.log("Treasury ", address(treasury));
        console.log("TipRouter", address(router));
        for (uint256 i; i < 5; ++i) {
            console.log(TICKERS[i], stocks[i]);
        }
        console.log("wrote deployments.1952.json");
    }

    /// @dev The addresses belong in the file the keeper and the web app read, and
    /// they belong there without anyone retyping them. Copied by hand, this is
    /// the step that leaves a frontend pointing at contracts nobody deployed.
    function _writeDeployment(
        address usdg,
        address signal,
        address amm,
        address treasury,
        address router,
        address[] memory stocks,
        address deployer,
        address keeper
    ) internal {
        string memory o = "deployment";
        vm.serializeAddress(o, "TapeSignal", signal);
        vm.serializeAddress(o, "MockAMM", amm);
        vm.serializeAddress(o, "MockTreasury", treasury);
        vm.serializeAddress(o, "TipRouter", router);
        vm.serializeAddress(o, "USDG", usdg);
        for (uint256 i; i < 5; ++i) {
            vm.serializeAddress(o, TICKERS[i], stocks[i]);
        }
        vm.serializeUint(o, "_chainId", block.chainid);
        vm.serializeString(o, "_rpc", "https://testrpc.xlayer.tech");
        vm.serializeString(o, "_explorer", "https://www.oklink.com/x-layer-testnet");
        vm.serializeAddress(o, "_deployer", deployer);
        vm.serializeAddress(o, "_keeper", keeper);
        // Everything worth reading happened at or after this block, so the log
        // scans have somewhere to start that is not the genesis of the chain.
        string memory out = vm.serializeUint(o, "_fromBlock", block.number);
        vm.writeJson(out, "./deployments.1952.json");
    }
}
