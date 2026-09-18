// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Fixed-price swap venue for testnet. The keeper pushes the issuer
/// price; the contract fills instantly at that price plus a spread.
/// Mainnet replaces this with the real Uniswap v3 pools on X Layer.
contract MockAMM {
    using SafeERC20 for IERC20;

    address public owner;
    address public keeper;
    IERC20 public immutable usdg;
    uint8 public immutable usdgDecimals;

    uint16 public spreadBps = 10; // 0.10%

    mapping(address stock => uint256 priceE8) public priceE8; // USD per share, 8 decimals

    event PriceSet(address indexed stock, uint256 priceE8);
    event Swapped(address indexed stock, address indexed to, uint256 usdgIn, uint256 stockOut, uint256 priceE8);
    event SoldBack(address indexed stock, address indexed to, uint256 stockIn, uint256 usdgOut, uint256 priceE8);

    error NotOwner();
    error NotKeeper();
    error NoPrice();
    error Slippage();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    constructor(address usdg_, address keeper_) {
        owner = msg.sender;
        usdg = IERC20(usdg_);
        usdgDecimals = IERC20Metadata(usdg_).decimals();
        keeper = keeper_;
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
    }

    function setSpreadBps(uint16 bps) external onlyOwner {
        spreadBps = bps;
    }

    function setPrice(address stock, uint256 price) external onlyKeeper {
        priceE8[stock] = price;
        emit PriceSet(stock, price);
    }

    function setPrices(address[] calldata stocks, uint256[] calldata prices) external onlyKeeper {
        for (uint256 i; i < stocks.length; ++i) {
            priceE8[stocks[i]] = prices[i];
            emit PriceSet(stocks[i], prices[i]);
        }
    }

    function quote(address stock, uint256 usdgIn) public view returns (uint256 stockOut) {
        uint256 p = priceE8[stock];
        if (p == 0) revert NoPrice();
        uint8 sd = IERC20Metadata(stock).decimals();
        // usdgIn / 10^usdgDecimals  ==  USD ; shares = USD / (priceE8 / 1e8)
        stockOut = (usdgIn * 1e8 * (10 ** sd)) / (p * (10 ** usdgDecimals));
        stockOut = (stockOut * (10_000 - spreadBps)) / 10_000;
    }

    function swapExactUsdgForStock(address stock, uint256 usdgIn, uint256 minOut, address to)
        external
        returns (uint256 stockOut)
    {
        stockOut = quote(stock, usdgIn);
        if (stockOut < minOut) revert Slippage();
        usdg.safeTransferFrom(msg.sender, address(this), usdgIn);
        uint256 bal = IERC20(stock).balanceOf(address(this));
        if (bal < stockOut) IMintable(stock).mint(address(this), stockOut - bal); // testnet inventory
        IERC20(stock).safeTransfer(to, stockOut);
        emit Swapped(stock, to, usdgIn, stockOut, priceE8[stock]);
    }

    function swapExactStockForUsdg(address stock, uint256 stockIn, uint256 minOut, address to)
        external
        returns (uint256 usdgOut)
    {
        uint256 p = priceE8[stock];
        if (p == 0) revert NoPrice();
        uint8 sd = IERC20Metadata(stock).decimals();
        usdgOut = (stockIn * p * (10 ** usdgDecimals)) / (1e8 * (10 ** sd));
        usdgOut = (usdgOut * (10_000 - spreadBps)) / 10_000;
        if (usdgOut < minOut) revert Slippage();
        IERC20(stock).safeTransferFrom(msg.sender, address(this), stockIn);
        uint256 bal = usdg.balanceOf(address(this));
        if (bal < usdgOut) IMintable(address(usdg)).mint(address(this), usdgOut - bal);
        usdg.safeTransfer(to, usdgOut);
        emit SoldBack(stock, to, stockIn, usdgOut, p);
    }
}
