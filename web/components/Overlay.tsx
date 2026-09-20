"use client";

import { useQuery } from "@tanstack/react-query";
import { createPublicClient, http, parseAbiItem, formatUnits } from "viem";
import { ABI, ADDR, xlayerTestnet } from "@/lib/chain";
import { id, TICKER_BY_ID } from "@/lib/hooks";

/** The piece a platform drops into a broadcast: transparent, no chrome, reads
 *  tips straight off the chain. Nothing here is a mock of a feed — these are the
 *  same events the creator's account was paid by. */

const client = createPublicClient({ chain: xlayerTestnet, transport: http() });

// This RPC answers eth_getLogs for 100 blocks at a time. Asking for the whole
// chain fails outright, so the range is walked in windows the node will answer,
// and only ever forward: what we already read stays read.
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

const WINDOW = 100n;
// An overlay shows what just happened, so it reads backwards from the tip of the
// chain and stops as soon as it has enough. Walking forward from the deployment
// block was fine on day one and hopeless by day three: X Layer had produced
// 150,000 blocks by then, which is 1,500 requests before the first card appears.
const CARDS = 6;
const WINDOWS_PER_TICK = 20n; // ~2,000 blocks per refresh, then further back if needed

type Scan<T> = { floor: bigint; logs: T[] };
const scans = new Map<string, Scan<never>>();

async function recentLogs<T extends { blockNumber: bigint | null }>(
  key: string,
  head: bigint,
  enough: (logs: T[]) => boolean,
  fetch: (a: bigint, b: bigint) => Promise<T[]>,
): Promise<T[]> {
  const prev = scans.get(key) as Scan<T> | undefined;
  let floor = prev ? prev.floor : head + 1n;
  const logs = prev ? prev.logs.slice() : [];

  for (let i = 0n; i < WINDOWS_PER_TICK && floor > 0n && !enough(logs); i++) {
    const end = floor - 1n;
    const start = end >= WINDOW ? end - WINDOW + 1n : 0n;
    logs.unshift(...(await fetch(start, end)));
    floor = start;
    scans.set(key, { floor, logs: logs.slice() } as Scan<never>);
  }

  // anything newer than where we started reading is picked up on every tick
  if (prev) {
    const top = logs.length ? (logs[logs.length - 1].blockNumber ?? 0n) + 1n : head;
    let start = top;
    while (start <= head) {
      const end = start + WINDOW - 1n > head ? head : start + WINDOW - 1n;
      logs.push(...(await fetch(start, end)));
      start = end + 1n;
    }
    scans.set(key, { floor, logs: logs.slice() } as Scan<never>);
  }

  return logs;
}

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

      type TipLog = Awaited<ReturnType<typeof client.getLogs<typeof TIPPED>>>[number];
      const tips = await recentLogs<TipLog>(
        `tips:${handle}`,
        head,
        (l) => l.length >= CARDS,
        (a, b) =>
          client.getLogs({
            address: ADDR.TipRouter,
            event: TIPPED,
            args: { creatorId: id(handle) },
            fromBlock: a,
            toBlock: b,
          }),
      );

      type BuyLog = Awaited<ReturnType<typeof client.getLogs<typeof BOUGHT>>>[number];
      const live = account && account !== "0x0000000000000000000000000000000000000000";
      let buys: BuyLog[] = [];
      if (live) {
        buys = await recentLogs<BuyLog>(
          `buys:${account}`,
          head,
          (l) => l.length >= CARDS * 2,
          (a, b) => client.getLogs({ address: account, event: BOUGHT, fromBlock: a, toBlock: b }),
        );
      }

      // A tip split across two names produces two buys, and showing one of them
      // would be a half-truth. Each tip claims the buys that happened after it
      // and before the next one.
      const ordered = tips.slice().sort((a, b) => Number(a.blockNumber! - b.blockNumber!));
      return ordered
        .map((t, i): Card => {
          const next = ordered[i + 1]?.blockNumber ?? undefined;
          const fills = buys
            .filter(
              (b) =>
                b.blockNumber! >= t.blockNumber! &&
                (next === undefined || next === null || b.blockNumber! < next),
            )
            .map((b) => ({
              ticker: TICKER_BY_ID[b.args.symbolId!.toLowerCase()] ?? "?",
              shares: b.args.tokensOut!,
            }));
          return { tipId: t.args.tipId!, fan: t.args.fan!, amount: t.args.amount!, fills };
        })
        .reverse()
        .slice(0, CARDS);
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
