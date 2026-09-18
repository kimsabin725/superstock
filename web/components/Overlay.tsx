"use client";

import { useQuery } from "@tanstack/react-query";
import { createPublicClient, http, parseAbiItem, formatUnits } from "viem";
import { ABI, ADDR, FROM_BLOCK, xlayerTestnet } from "@/lib/chain";
import { id, TICKER_BY_ID } from "@/lib/hooks";

/** The piece a platform drops into a broadcast: transparent, no chrome, reads
 *  tips straight off the chain. Nothing here is a mock of a feed — these are the
 *  same events the creator's account was paid by. */

const client = createPublicClient({ chain: xlayerTestnet, transport: http() });

// This RPC answers eth_getLogs for 100 blocks at a time. Asking for the whole
// chain fails outright, so the range is walked in windows the node will answer,
// and only ever forward: what we already read stays read.
const WINDOW = 100n;

type Scan = { to: bigint; logs: unknown[] };
const seen = new Map<string, Scan>();

async function logsSince(key: string, from: bigint, head: bigint, fetch: (a: bigint, b: bigint) => Promise<unknown[]>) {
  const prev = seen.get(key);
  let start = prev ? prev.to + 1n : from;
  const out = prev ? prev.logs.slice() : [];
  while (start <= head) {
    const end = start + WINDOW - 1n > head ? head : start + WINDOW - 1n;
    out.push(...(await fetch(start, end)));
    // Bank each window as it lands. Saving only at the end meant a scan that
    // took longer than the refresh interval restarted forever and never
    // reached the newest tip.
    seen.set(key, { to: end, logs: out.slice() });
    start = end + 1n;
  }
  return out;
}

const TIPPED = parseAbiItem(
  "event Tipped(bytes32 indexed platformId, bytes32 indexed creatorId, address indexed fan, uint256 amount, uint256 fee, uint8 symbolChoice, bytes32 msgHash, uint256 tipId)",
);
const BOUGHT = parseAbiItem(
  "event Bought(bytes32 indexed symbolId, uint256 usdgIn, uint256 tokensOut, uint256 priceRefE8)",
);

type Fill = { ticker: string; shares: bigint };

type Card = {
  tipId: bigint;
  fan: `0x${string}`;
  amount: bigint;
  fills: Fill[];
};

export function Overlay({ handle }: { handle: string }) {
  const { data } = useQuery({
    queryKey: ["overlay", handle],
    refetchInterval: 5000,
    staleTime: 2000,
    queryFn: async (): Promise<Card[]> => {
      const account = (await client.readContract({
        address: ADDR.TipRouter,
        abi: ABI.TipRouter,
        functionName: "accounts",
        args: [id(handle)],
      })) as `0x${string}`;

      const head = await client.getBlockNumber();

      const tips = (await logsSince(`tips:${handle}`, FROM_BLOCK, head, (a, b) =>
        client.getLogs({
          address: ADDR.TipRouter,
          event: TIPPED,
          args: { creatorId: id(handle) },
          fromBlock: a,
          toBlock: b,
        }),
      )) as Awaited<ReturnType<typeof client.getLogs<typeof TIPPED>>>;

      const live = account && account !== "0x0000000000000000000000000000000000000000";
      const buys = live
        ? ((await logsSince(`buys:${account}`, FROM_BLOCK, head, (a, b) =>
            client.getLogs({ address: account, event: BOUGHT, fromBlock: a, toBlock: b }),
          )) as Awaited<ReturnType<typeof client.getLogs<typeof BOUGHT>>>)
        : [];

      // A tip split across two names produces two buys, and showing one of them
      // would be a half-truth. Each tip claims the buys that happened after it
      // and before the next one.
      const ordered = tips.slice().sort((a, b) => Number(a.blockNumber! - b.blockNumber!));
      return ordered
        .map((t, i): Card => {
          const next = ordered[i + 1]?.blockNumber;
          const fills = buys
            .filter(
              (b) =>
                b.blockNumber! >= t.blockNumber! && (next === undefined || b.blockNumber! < next),
            )
            .map((b) => ({
              ticker: TICKER_BY_ID[b.args.symbolId!.toLowerCase()] ?? "?",
              shares: b.args.tokensOut!,
            }));
          return { tipId: t.args.tipId!, fan: t.args.fan!, amount: t.args.amount!, fills };
        })
        .reverse()
        .slice(0, 6);
    },
  });

  return (
    <div className="overlay-root flex min-h-screen items-end justify-start bg-transparent p-6">
      <div className="grid w-[380px] gap-2.5">
        {(data ?? []).map((c) => (
          <div
            key={String(c.tipId)}
            className="rounded-xl border border-white/10 bg-black/70 px-4 py-3 backdrop-blur"
          >
            <div className="flex items-baseline gap-2">
              <span className="mono text-[13px] text-white/60">
                {c.fan.slice(0, 6)}…{c.fan.slice(-4)}
              </span>
              <span className="ml-auto text-[17px] font-semibold text-white">
                ${Number(formatUnits(c.amount, 6)).toFixed(2)}
              </span>
            </div>
            {c.fills.length === 0 ? (
              <p className="mt-1 text-[13px] text-hold">waiting for the open</p>
            ) : (
              <p className="mt-1 text-[13px] text-accent">
                {c.fills
                  .map((f) => `${Number(formatUnits(f.shares, 18)).toFixed(6)} ${f.ticker}`)
                  .join("  ·  ")}
              </p>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
