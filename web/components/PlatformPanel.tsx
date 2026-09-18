"use client";

import { useState } from "react";
import { useReadContract } from "wagmi";
import { ABI, ADDR, explorerAddr } from "@/lib/chain";
import { id } from "@/lib/hooks";

const DEMO = [
  { key: "orbit", label: "A live streaming app", fee: "10%" },
  { key: "twitchlike", label: "A creator platform", fee: "5%" },
  { key: "direct", label: "A bare profile link", fee: "0%" },
];

export function PlatformPanel() {
  const [key, setKey] = useState("orbit");
  const { data } = useReadContract({
    address: ADDR.TipRouter,
    abi: ABI.TipRouter,
    functionName: "platforms",
    args: [id(key)],
    query: { refetchInterval: 8000 },
  });
  const p = data as readonly [`0x${string}`, number, boolean] | undefined;

  return (
    <div className="grid gap-6 md:grid-cols-[1fr_320px]">
      <div className="grid gap-5">
        <div>
          <p className="text-[12.5px] uppercase tracking-wider text-inkdim">For platforms</p>
          <h1 className="mt-1 text-[24px] font-semibold">One transaction to turn tips into stock</h1>
          <p className="mt-2 max-w-lg text-[14px] leading-relaxed text-inkdim">
            Register a payout address and a fee, drop the widget into your overlay, and your cut
            settles in stablecoin on every tip. No card rails, no chargebacks, no custody on your side.
          </p>
        </div>

        <div className="card p-5">
          <h3 className="mb-3 text-[13px] font-semibold">Registered on chain</h3>
          <div className="mb-4 flex gap-2">
            {DEMO.map((d) => (
              <button
                key={d.key}
                className={key === d.key ? "btn px-3 py-2 text-[13px]" : "btn-ghost px-3 py-2 text-[13px]"}
                onClick={() => setKey(d.key)}
              >
                {d.label}
              </button>
            ))}
          </div>
          <dl className="grid gap-2 text-[13px]">
            <Row k="Platform id" v={<span className="mono">{key}</span>} />
            <Row k="Fee" v={p ? `${Number(p[1]) / 100}%` : "—"} />
            <Row
              k="Payout address"
              v={p ? (
                <a className="mono text-accent hover:underline" href={explorerAddr(p[0])} target="_blank" rel="noreferrer">
                  {p[0].slice(0, 10)}…{p[0].slice(-8)}
                </a>
              ) : "—"}
            />
            <Row k="Status" v={p?.[2] ? <span className="text-good">active</span> : <span className="text-inkdim">inactive</span>} />
          </dl>
        </div>

        <div className="card p-5">
          <h3 className="mb-3 text-[13px] font-semibold">The integration</h3>
          <pre className="mono overflow-x-auto rounded-lg bg-panel2 p-4 text-[12px] leading-relaxed text-inkdim">
{`// once, from your treasury wallet
router.registerPlatform(id("yourapp"), payoutAddress, 1000)  // 10%

// then, per tip — the fan signs this, not you
router.tip(id("yourapp"), id(creatorHandle), amount, messageHash, choice)`}
          </pre>
          <p className="mt-3 text-[12.5px] leading-relaxed text-inkdim">
            The fee cap is 50% and it is enforced by the contract, not by us. Deactivating a platform
            stops new tips immediately and touches nobody&apos;s balance.
          </p>
        </div>
      </div>

      <div className="grid content-start gap-4">
        <div className="card p-4 text-[12.5px] leading-relaxed text-inkdim">
          <p className="mb-2 text-[13px] font-semibold text-ink">Honest about the demo</p>
          <p>
            The overlay here is our own mock of a streaming UI — we have not integrated with any
            platform. What is real is the surface: registration is one transaction, and the cut
            settles on chain on every tip.
          </p>
        </div>
      </div>
    </div>
  );
}

function Row({ k, v }: { k: string; v: React.ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-4 border-b border-line pb-2 last:border-0">
      <dt className="text-inkdim">{k}</dt>
      <dd>{v}</dd>
    </div>
  );
}
