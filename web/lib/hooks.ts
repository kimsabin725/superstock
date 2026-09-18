"use client";

import { keccak256, stringToHex, formatUnits } from "viem";
import { useSyncExternalStore } from "react";
import { useReadContract, useReadContracts } from "wagmi";
import { ABI, ADDR, POOL } from "./chain";

export const id = (s: string) => keccak256(stringToHex(s));

/** Wall-clock read the way React wants an outside value read: pure during
 *  render, ticking on its own, and undefined on the server so the markup the
 *  client hydrates into is the markup the server sent. */
export function useHydrated(): boolean {
  return useSyncExternalStore(
    () => () => {},
    () => true,
    () => false,
  );
}

export function useNow(everyMs = 30_000): number | undefined {
  return useSyncExternalStore(
    (onChange) => {
      const t = setInterval(onChange, everyMs);
      return () => clearInterval(t);
    },
    () => Math.floor(Date.now() / everyMs) * everyMs,
    () => undefined,
  );
}

export const usd = (v: bigint | undefined, dp = 2) =>
  v === undefined ? "—" : Number(formatUnits(v, 6)).toLocaleString("en-US", {
    minimumFractionDigits: dp,
    maximumFractionDigits: dp,
  });

export const shares = (v: bigint | undefined) =>
  v === undefined ? "—" : Number(formatUnits(v, 18)).toLocaleString("en-US", {
    minimumFractionDigits: 6,
    maximumFractionDigits: 6,
  });

/** The creator's account address.
 *
 *  `loading` matters: an address we have not fetched yet and a handle that was
 *  never onboarded both read as "no address", and telling a creator their
 *  account does not exist because an RPC call is a second slow is worse than
 *  saying nothing for that second. */
export function useCreatorAccount(handle: string): {
  account?: `0x${string}`;
  loading: boolean;
} {
  const hydrated = useHydrated();
  const { data, isLoading, isError } = useReadContract({
    address: ADDR.TipRouter,
    abi: ABI.TipRouter,
    functionName: "accounts",
    args: [id(handle)],
    query: { refetchInterval: 6000 },
  });
  const a = data as `0x${string}` | undefined;
  return {
    account: a && a !== "0x0000000000000000000000000000000000000000" ? a : undefined,
    // Before hydration nothing has been asked yet, so the server must not render
    // the "no such creator" copy that a browser would only ever show after a
    // real answer came back.
    loading: !hydrated || (isLoading && !isError),
  };
}

/** What the tape says about every symbol in the demo pool, right now. */
export function useTape() {
  const { data } = useReadContracts({
    contracts: POOL.map((t) => ({
      address: ADDR.TapeSignal,
      abi: ABI.TapeSignal,
      functionName: "check" as const,
      args: [id(t)],
    })),
    query: { refetchInterval: 8000 },
  });
  const out: Record<string, { allow: boolean; reason: number }> = {};
  POOL.forEach((t, i) => {
    const r = data?.[i]?.result as readonly [boolean, number] | undefined;
    if (r) out[t] = { allow: r[0], reason: Number(r[1]) };
  });
  return out;
}

export type Position = {
  symbolId: `0x${string}`;
  token: `0x${string}`;
  balance: bigint;
  pinnedPending: bigint;
  dividendUsd: bigint;
};

export function useStatement(account?: `0x${string}`) {
  const { data, refetch } = useReadContract({
    address: account,
    abi: ABI.CreatorAccount,
    functionName: "statement",
    query: { enabled: !!account, refetchInterval: 6000 },
  });
  const d = data as readonly [Position[], bigint, bigint, bigint] | undefined;
  return {
    positions: d?.[0] ?? [],
    pending: d?.[1],
    treasury: d?.[2],
    yieldEarned: d?.[3],
    refetch,
  };
}

/** Maps a symbolId back to its ticker for display. */
export const TICKER_BY_ID: Record<string, string> = Object.fromEntries(
  POOL.map((t) => [id(t).toLowerCase(), t]),
);
