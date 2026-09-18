"use client";

import { POOL, REASONS } from "@/lib/chain";
import { useTape } from "@/lib/hooks";

/** What the contract would answer right now, for every name in the pool.
 *  Green means a buy goes through; amber means the cash waits, and says why. */
export function TapeStrip({ only }: { only?: readonly string[] }) {
  const tape = useTape();
  const list = only ?? POOL;

  return (
    <div className="card p-4">
      <div className="mb-3 flex items-baseline justify-between">
        <h3 className="text-[13px] font-semibold">The tape</h3>
        <span className="text-[11px] text-inkdim">read from the contract, refreshed live</span>
      </div>
      <div className="grid gap-2">
        {list.map((t) => {
          const s = tape[t];
          const allow = s?.allow;
          return (
            <div
              key={t}
              className="flex items-center gap-3 rounded-lg bg-panel2 px-3 py-2.5"
            >
              <span
                className="h-2 w-2 shrink-0 rounded-full"
                style={{ background: allow === undefined ? "#3a4256" : allow ? "var(--good)" : "var(--hold)" }}
              />
              <span className="mono w-16 text-[13px]">{t}</span>
              <span className="text-[12.5px] text-inkdim">
                {s ? REASONS[s.reason] ?? `code ${s.reason}` : "reading…"}
              </span>
              <span
                className="mono ml-auto text-[11px]"
                style={{ color: allow ? "var(--good)" : "var(--hold)" }}
              >
                {s ? (allow ? "BUY" : "HOLD") : ""}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
