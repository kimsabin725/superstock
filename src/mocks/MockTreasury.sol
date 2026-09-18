// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintableAsset {
    function mint(address to, uint256 amount) external;
}

/// @notice Stand-in for Centrifuge deJTRSY: an ERC-4626 vault over USDG that
/// accrues a flat 4.5%/yr. Mainnet swaps this for the real token via an adapter.
contract MockTreasury is ERC4626 {
    uint256 public constant RATE_BPS = 450; // 4.5% per year
    uint256 public lastAccrual;

    event Accrued(uint256 interest, uint256 timestamp);

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock Tokenized Treasury", "mdeJTRSY") {
        lastAccrual = block.timestamp;
    }

    function pendingInterest() public view returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 dt = block.timestamp - lastAccrual;
        if (bal == 0 || dt == 0) return 0;
        return (bal * RATE_BPS * dt) / (10_000 * 365 days);
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + pendingInterest();
    }

    /// @dev Mints the accrued interest so the vault can actually pay it out.
    function accrue() public {
        uint256 interest = pendingInterest();
        lastAccrual = block.timestamp;
        if (interest > 0) {
            IMintableAsset(asset()).mint(address(this), interest);
            emit Accrued(interest, block.timestamp);
        }
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        accrue();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        accrue();
        super._withdraw(caller, receiver, owner_, assets, shares);
    }
}
