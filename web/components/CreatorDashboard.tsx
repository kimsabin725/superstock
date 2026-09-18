"use client";

import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { ABI, ADDR, REASONS, explorerAddr } from "@/lib/chain";
import { shares, usd, useCreatorAccount, useNow, useStatement, useTape, TICKER_BY_ID } from "@/lib/hooks";
import { TapeStrip } from "./TapeStrip";

export function CreatorDashboard({ handle }: { handle: string }) {
  const { address } = useAccount();
  const { account, loading } = useCreatorAccount(handle);
  const { positions, pending, treasury, yieldEarned } = useStatement(account);
  const tape = useTape();
  const { writeContract, isPending, error } = useWriteContract();
  const now = useNow();

  const { data: lockUntil } = useReadContract({
    address: account, abi: ABI.CreatorAccount, functionName: "lockUntil",
    query: { enabled: !!account },
  });
  const { data: owner } = useReadContract({
    address: account, abi: ABI.CreatorAccount, functionName: "owner",
    query: { enabled: !!account },
  });
  const { data: tipCount } = useReadContract({
    address: account, abi: ABI.CreatorAccount, functionName: "tipCount",
    query: { enabled: !!account, refetchInterval: 6000 },
  });
  const { data: totalTipped } = useReadContract({
    address: account, abi: ABI.CreatorAccount, functionName: "totalTipped",
    query: { enabled: !!account, refetchInterval: 6000 },
  });

  if (loading) return <div className="card p-6 text-[14px] text-inkdim">Looking up {handle}…</div>;
  if (!account) return <div className="card p-6 text-[14px] text-inkdim">No account for {handle}.</div>;

  const isOwner = !!address && !!owner && address.toLowerCase() === (owner as string).toLowerCase();
  const lockDate = lockUntil ? new Date(Number(lockUntil) * 1000) : undefined;
  const locked = lockDate && now !== undefined ? lockDate.getTime() > now : undefined;
  const tickers = positions.map((p) => TICKER_BY_ID[p.symbolId.toLowerCase()] ?? "?");

  return (
    <div className="grid gap-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <p className="text-[12.5px] uppercase tracking-wider text-inkdim">Creator account</p>
          <h1 className="mono mt-1 text-[24px] font-semibold">{handle}</h1>
          <a
            className="mono mt-1 inline-block max-w-full break-all text-[12px] text-accent hover:underline"
            href={explorerAddr(account)} target="_blank" rel="noreferrer"
          >
            {account}
          </a>
        </div>
        <div className="flex gap-6 text-right">
          <Stat label="Tips received" value={tipCount !== undefined ? String(tipCount) : "—"} />
          <Stat label="Total tipped" value={`$${usd(totalTipped as bigint | undefined)}`} />
        </div>
      </div>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-[minmax(0,1fr)_320px]">
        <div className="grid min-w-0 grid-cols-1 gap-4">
          <div className="card p-5">
            <h3 className="mb-4 text-[13px] font-semibold">Holdings</h3>
            <div className="grid gap-2">
              {positions.map((p, i) => {
                const t = tickers[i];
                const s = tape[t];
                return (
                  <div key={p.symbolId} className="flex flex-wrap items-baseline gap-x-3 gap-y-1 rounded-lg bg-panel2 px-3.5 py-3">
                    <span className="mono w-16 text-[14px] font-semibold">{t}</span>
                    <span className="mono text-[14px]">{shares(p.balance)}</span>
                    <span className="text-[12px] text-inkdim">shares</span>
                    {p.pinnedPending > 0n && (
                      <span className="text-[12px] text-hold">
                        ${usd(p.pinnedPending)} waiting{s && !s.allow ? ` — ${REASONS[s.reason]}` : ""}
                      </span>
                    )}
                    {p.dividendUsd > 0n && (
                      <span className="ml-auto text-[12px] text-good">
                        ${usd(p.dividendUsd)} dividends
                      </span>
                    )}
                  </div>
                );
              })}
            </div>
          </div>

          <div className="card p-5">
            <h3 className="mb-4 text-[13px] font-semibold">Cash</h3>
            <div className="grid gap-3 sm:grid-cols-3">
              <Money label="Waiting to buy" value={pending} hint="held until the market opens" />
              <Money label="In treasuries" value={treasury} hint="earning while it waits" />
              <Money label="Yield earned" value={yieldEarned} hint="added to the next buy" good />
            </div>
          </div>

          <div className="card p-5">
            <h3 className="text-[13px] font-semibold">Withdraw</h3>
            <p className="mt-2 text-[12.5px] leading-relaxed text-inkdim">
              Cash is never locked. Stock is locked until{" "}
              <span className="text-ink">{lockDate?.toLocaleDateString() ?? "—"}</span>
              {locked === undefined
                ? "."
                : locked
                  ? " — the creator set that themselves, and it can only be extended."
                  : " — the lock has passed."}
            </p>
            <div className="mt-4 flex gap-2">
              <button
                className="btn px-3.5 py-2 text-[13px]"
                disabled={!isOwner || isPending || !pending}
                onClick={() =>
                  writeContract({
                    address: account, abi: ABI.CreatorAccount, functionName: "withdraw",
                    args: [ADDR.USDG, pending!],
                  })
                }
              >
                Withdraw cash
              </button>
              <button
                className="btn-ghost px-3.5 py-2 text-[13px]"
                disabled={isPending}
                onClick={() =>
                  writeContract({ address: account, abi: ABI.CreatorAccount, functionName: "executeBuys" })
                }
              >
                Buy now
              </button>
            </div>
            {!isOwner && (
              <p className="mt-3 text-[12px] text-inkdim">
                Connect the creator&apos;s wallet to withdraw. Anyone may trigger a buy.
              </p>
            )}
            {error && (
              <p className="mt-3 text-[12px] text-hold">
                {error.message.split("\n")[0]}
              </p>
            )}
          </div>
        </div>

        <div className="grid content-start gap-4">
          <TapeStrip only={tickers} />
        </div>
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-[11.5px] uppercase tracking-wider text-inkdim">{label}</p>
      <p className="mono mt-1 text-[18px] font-semibold">{value}</p>
    </div>
  );
}

function Money({ label, value, hint, good }: { label: string; value?: bigint; hint: string; good?: boolean }) {
  return (
    <div className="rounded-lg bg-panel2 px-3.5 py-3">
      <p className="text-[11.5px] uppercase tracking-wider text-inkdim">{label}</p>
      <p className="mono mt-1 text-[18px] font-semibold" style={good ? { color: "var(--good)" } : undefined}>
        ${usd(value)}
      </p>
      <p className="mt-1 text-[11.5px] text-inkdim">{hint}</p>
    </div>
  );
}
