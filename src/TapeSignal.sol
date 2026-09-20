// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @notice Mini signal registry. The keeper writes what the tape says; the
/// contract decides allow/hold. Reason codes follow the shared table (§13);
/// this registry only ever emits 0 / 100 / 101 / 102 / 110 / 2xx / 300 / 400 / 402 / 900.
contract TapeSignal {
    uint8 internal constant SESSION_MARKET = 0;
    uint8 internal constant SESSION_EXTENDED = 1;
    uint8 internal constant SESSION_CLOSED = 2;
    uint8 internal constant SESSION_LUNCH = 3;
    uint8 internal constant SESSION_UNKNOWN = 4;

    struct Signal {
        uint8 session;
        uint16 haltCode; // 0 = trading, else 200/201/202/203/210/220
        uint40 caEffectiveAt; // 0 = no upcoming corporate action
        uint40 priceUpdatedAt;
        uint40 observedAt;
    }

    address public owner;
    address public keeper;

    /// @dev fail-safe windows, all in seconds
    uint40 public maxSignalAge = 900;
    uint40 public maxPriceAge = 900;
    uint40 public caWindow = 1800;

    mapping(bytes32 symbolId => Signal) public signals;

    event SignalSet(bytes32 indexed symbolId, uint8 session, uint16 haltCode, uint40 caEffectiveAt, uint40 observedAt);
    event KeeperSet(address indexed keeper);
    event ParamsSet(uint40 maxSignalAge, uint40 maxPriceAge, uint40 caWindow);

    error NotOwner();
    error NotKeeper();
    error LengthMismatch();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    /// @dev Deploys owned and signed by whoever sent it, then hands the signing
    /// key over with `setKeeper` — the same shape as the venue, so a deployment
    /// never has a moment where nobody can write and never needs the keeper's
    /// key present at deploy time.
    constructor() {
        owner = msg.sender;
        keeper = msg.sender;
        emit KeeperSet(msg.sender);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setParams(uint40 maxSignalAge_, uint40 maxPriceAge_, uint40 caWindow_) external onlyOwner {
        maxSignalAge = maxSignalAge_;
        maxPriceAge = maxPriceAge_;
        caWindow = caWindow_;
        emit ParamsSet(maxSignalAge_, maxPriceAge_, caWindow_);
    }

    function setBatch(bytes32[] calldata symbolIds, Signal[] calldata sigs) external onlyKeeper {
        if (symbolIds.length != sigs.length) revert LengthMismatch();
        for (uint256 i; i < symbolIds.length; ++i) {
            signals[symbolIds[i]] = sigs[i];
            emit SignalSet(symbolIds[i], sigs[i].session, sigs[i].haltCode, sigs[i].caEffectiveAt, sigs[i].observedAt);
        }
    }

    /// @notice The only question the account layer asks: buy now, or hold?
    /// @return allow true = execute, false = keep the cash
    /// @return reason code from the shared table; informational when allow == true
    function check(bytes32 symbolId) public view returns (bool allow, uint16 reason) {
        Signal memory s = signals[symbolId];

        // keeper outage or unknown symbol -> hold (fail-safe)
        if (s.observedAt == 0 || block.timestamp > uint256(s.observedAt) + maxSignalAge) return (false, 900);

        if (s.haltCode != 0) return (false, s.haltCode);

        if (s.caEffectiveAt != 0) {
            uint256 ca = s.caEffectiveAt;
            uint256 lo = ca > caWindow ? ca - caWindow : 0;
            if (block.timestamp >= lo && block.timestamp <= ca + caWindow) return (false, 300);
        }

        // A shut market is why there is no price, not the other way round. Asked
        // on a Sunday, this contract used to answer "no price available", which
        // is true and useless. The session is the cause, so the session answers.
        if (s.session == SESSION_CLOSED) return (false, 100);
        if (s.session == SESSION_LUNCH) return (false, 102);
        if (s.session == SESSION_UNKNOWN) return (false, 110);

        if (s.priceUpdatedAt == 0) return (false, 402);
        if (block.timestamp > uint256(s.priceUpdatedAt) + maxPriceAge) return (false, 400);

        if (s.session == SESSION_EXTENDED) return (true, 101);

        return (true, 0);
    }
}
