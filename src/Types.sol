// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @notice What a creator asked for, in one struct. Set at onboarding, editable
/// by the creator alone; the lock can only ever be extended.
struct CreatorConfig {
    address owner;
    bytes32[] symbols;
    uint16[] weightsBps; // must sum to 10_000
    uint40 lockUntil;
    bool receiveUsdgOnly; // creator wants cash, not stock
    bool sweepToTreasury; // park idle cash in tokenized treasuries while it waits
}

struct Position {
    bytes32 symbolId;
    address token;
    uint256 balance;
    uint256 pinnedPending;
    uint256 dividendUsd;
}

interface ISwapVenue {
    function quote(address stock, uint256 usdgIn) external view returns (uint256);
    function swapExactUsdgForStock(address stock, uint256 usdgIn, uint256 minOut, address to)
        external
        returns (uint256);
}

interface ITapeSignal {
    function check(bytes32 symbolId) external view returns (bool allow, uint16 reason);
}

interface ITipRouter {
    function tokenOf(bytes32 symbolId) external view returns (address);
    function usdg() external view returns (address);
    function venue() external view returns (address);
    function signal() external view returns (address);
    function treasury() external view returns (address);
    function keeper() external view returns (address);
}

interface ICreatorAccount {
    function initialize(address router_, CreatorConfig calldata cfg) external;
    function deposit(address fan, uint256 amount, uint8 symbolChoice) external;
}
