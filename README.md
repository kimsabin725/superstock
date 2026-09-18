# Super Stock

Turn creator tips into tokenized stocks on X Layer.

A fan tips in stablecoin. In the same transaction the platform's cut leaves as
stablecoin and the rest lands in the creator's own account, where it becomes the
stocks that creator chose — but only while the underlying market is actually open.
When it isn't, the cash waits, earns treasury yield, and buys at the next open.

## Why this is not a broker

The fan sends stablecoin. The creator's own account buys, under rules the creator
set and can change. Nothing here takes custody, and nothing here decides for anyone.

## The rule layer

`TapeSignal` is a small registry the keeper writes: session, halt, corporate-action
window, price freshness. `CreatorAccount` asks one question before every buy —
allow, or hold? — and the answer is a code from a fixed table, not a judgement call.

If the keeper stops writing, everything holds. Silence is never read as "all clear".

| holds because | code |
|---|---|
| underlying market closed | 100 |
| HKEX lunch break | 102 |
| exchange or regulatory halt | 200–220 |
| inside a corporate-action window | 300 |
| price went stale | 400 |
| keeper went quiet | 900 |

A halt on one name never blocks the others.

## What is mocked, and what is not

On testnet the stablecoin, the stock wrappers, the swap venue and the treasury vault
are stand-ins. The signals are real — session and corporate-action data come from the
issuer API, halts from the exchange feed. On X Layer mainnet the stand-ins are replaced
by USDG, the real xStocks wrappers, the existing Uniswap v3 pools and a tokenized
treasury; no contract logic changes, only addresses.

## Deployed — X Layer testnet (chain 1952)

See `deployments.1952.json`. Two keys, on purpose: the keeper signs the tape and
the marks and holds nothing else, while the contracts' owner is a separate
address that never signs on a schedule.

## Known limits

We would rather you read these here than find them yourself.

1. **The stand-ins are stand-ins.** On testnet the stablecoin, the stock wrappers,
   the swap venue and the treasury vault are ours. Only the signals are real.
2. **Buys carry no slippage bound.** Against a fixed-price venue that is exact;
   against a real pool it is not, and a minimum-out has to be set before any of
   this touches mainnet.
3. **One keeper.** If it stops, every buy holds — that is the designed behaviour,
   and it is tested — but nothing buys until it is back.
4. **The streaming overlay is our own mock.** We have not integrated with any
   platform. The registration transaction behind it is real.
5. **Most names have no on-chain oracle.** Chainlink covers 13 xStocks on X Layer;
   the other 764 fall back to the issuer's own mark, which is a single source.
6. **Dividends are recorded, not reconciled.** The keeper writes what it observed
   so the statement can show it; it does not prove the rebase against balances.

## Build

```
forge test           # 39 tests
forge script script/Deploy.s.sol   --rpc-url $XLAYER_TESTNET_RPC --broadcast
forge script script/FirstTip.s.sol --rpc-url $XLAYER_TESTNET_RPC --broadcast
```

## License

Apache-2.0.
