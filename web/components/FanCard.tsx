"use client";

import { explorerTx } from "@/lib/chain";

/** What the fan gets to keep and share. The numbers on it are the ones the
 *  chain recorded, not a promise about them. */
export function FanCard({
  handle, amount, pick, hash, message,
}: { handle: string; amount: string; pick: string; hash: `0x${string}`; message: string }) {
  return (
    <div className="card overflow-hidden">
      <div className="bg-gradient-to-br from-[#1b2540] to-[#12151d] px-6 py-7">
        <p className="text-[11.5px] uppercase tracking-[0.18em] text-inkdim">You bought them stock</p>
        <p className="mt-3 text-[30px] font-semibold leading-tight">
          ${amount} <span className="text-inkdim">→</span> {pick}
        </p>
        <p className="mono mt-1.5 text-[13px] text-inkdim">for {handle}</p>
        {message && <p className="mt-4 max-w-sm text-[14px] leading-relaxed">“{message}”</p>}
      </div>
      <div className="flex items-center gap-3 border-t border-line px-6 py-3 text-[12px]">
        <span className="text-inkdim">on chain</span>
        <a className="mono break-all text-accent hover:underline" href={explorerTx(hash)} target="_blank" rel="noreferrer">
          {hash.slice(0, 12)}…{hash.slice(-8)}
        </a>
      </div>
    </div>
  );
}
