"use client";

import { keccak256, stringToHex, formatUnits } from "viem";
import { useReadContract, useReadContracts } from "wagmi";
import { ABI, ADDR, POOL } from "./chain";

export const id = (s: string) => keccak256(stringToHex(s));

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

/** The creator's account address, or undefined if that handle is not onboarded. */
export function useCreatorAccount(handle: string) {
  const { data } = useReadContract({
    address: ADDR.TipRouter,
    abi: ABI.TipRouter,
    functionName: "accounts",
    args: [id(handle)],
    query: { refetchInterval: 6000 },
  });
  const a = data as `0x${string}` | undefined;
  return a && a !== "0x0000000000000000000000000000000000000000" ? a : undefined;
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
