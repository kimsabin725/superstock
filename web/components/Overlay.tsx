"use client";

import { useQuery } from "@tanstack/react-query";
import { createPublicClient, http, parseAbiItem, formatUnits } from "viem";
import { ABI, ADDR, xlayerTestnet } from "@/lib/chain";
import { id, TICKER_BY_ID } from "@/lib/hooks";

/** The piece a platform drops into a broadcast: transparent, no chrome, reads
 *  tips straight off the chain. Nothing here is a mock of a feed — these are the
 *  same events the creator's account was paid by. */

const client = createPublicClient({ chain: xlayerTestnet, transport: http() });

const TIPPED = parseAbiItem(
  "event Tipped(bytes32 indexed platformId, bytes32 indexed creatorId, address indexed fan, uint256 amount, uint256 fee, uint8 symbolChoice, bytes32 msgHash, uint256 tipId)",
);
const BOUGHT = parseAbiItem(
  "event Bought(bytes32 indexed symbolId, uint256 usdgIn, uint256 tokensOut, uint256 priceRefE8)",
);

type Card = {
  tipId: bigint;
  fan: `0x${string}`;
  amount: bigint;
  ticker?: string;
  shares?: bigint;
};

export function Overlay({ handle }: { handle: string }) {
  const { data } = useQuery({
    queryKey: ["overlay", handle],
    refetchInterval: 5000,
    queryFn: async (): Promise<Card[]> => {
      const account = (await client.readContract({
        address: ADDR.TipRouter,
        abi: ABI.TipRouter,
        functionName: "accounts",
        args: [id(handle)],
      })) as `0x${string}`;

      const tips = await client.getLogs({
        address: ADDR.TipRouter,
        event: TIPPED,
        args: { creatorId: id(handle) },
        fromBlock: 0n,
      });

      const buys =
        account && account !== "0x0000000000000000000000000000000000000000"
          ? await client.getLogs({ address: account, event: BOUGHT, fromBlock: 0n })
          : [];

      // pair each tip with the buy it turned into, newest first
      const cards = tips.slice(-6).reverse().map((t): Card => {
        const match = buys.find((b) => b.blockNumber >= t.blockNumber);
        return {
          tipId: t.args.tipId!,
          fan: t.args.fan!,
          amount: t.args.amount!,
          ticker: match ? TICKER_BY_ID[match.args.symbolId!.toLowerCase()] : undefined,
          shares: match?.args.tokensOut,
        };
      });
      return cards;
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
            <p className="mt-1 text-[13px] text-accent">
              {c.ticker && c.shares !== undefined
                ? `bought ${Number(formatUnits(c.shares, 18)).toFixed(6)} ${c.ticker}`
                : "waiting for the open"}
            </p>
          </div>
        ))}
      </div>
    </div>
  );
}
