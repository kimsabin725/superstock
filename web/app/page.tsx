import Link from "next/link";
import { Chrome } from "@/components/Chrome";
import { TapeStrip } from "@/components/TapeStrip";
import { ADDR, explorerAddr } from "@/lib/chain";

export default function Home() {
  return (
    <Chrome>
      <div className="grid grid-cols-1 gap-8 md:grid-cols-[minmax(0,1fr)_320px]">
        <div className="grid min-w-0 grid-cols-1 gap-6">
          <div>
            <h1 className="text-[34px] font-semibold leading-[1.15] tracking-tight">
              Tips that arrive as stock.
            </h1>
            <p className="mt-3 max-w-lg text-[15px] leading-relaxed text-inkdim">
              A fan pays in stablecoin. In the same transaction the platform&apos;s cut leaves as
              stablecoin and the rest becomes the stock the creator chose to be paid in — bought in
              their own account, at the market price, while the market is open.
            </p>
            <p className="mt-3 max-w-lg text-[15px] leading-relaxed text-inkdim">
              When it isn&apos;t open, nothing is forced through. The cash waits, earns treasury
              yield, and buys at the next open. The reason it waited is on chain.
            </p>
          </div>

          <div className="flex flex-wrap gap-3">
            <Link className="btn px-4 py-2.5 text-[14px]" href="/c/@indiemusician">
              Tip a creator
            </Link>
            <Link className="btn-ghost px-4 py-2.5 text-[14px]" href="/dashboard/@indiemusician">
              See the account
            </Link>
            <Link className="btn-ghost px-4 py-2.5 text-[14px]" href="/platform">
              For platforms
            </Link>
          </div>

          <div className="card p-5">
            <h3 className="text-[13px] font-semibold">What is real, and what is a stand-in</h3>
            <div className="mt-3 grid gap-2.5 text-[13px] leading-relaxed text-inkdim">
              <p>
                <span className="text-good">Real:</span> the session, halt and corporate-action
                signals come from the issuer&apos;s own feed and the exchange halt feed, read by a
                keeper and written on chain. Every contract here is deployed on X Layer testnet and
                every number on these pages is read back from it.
              </p>
              <p>
                <span className="text-hold">Stand-in:</span> on testnet the stablecoin, the stock
                wrappers, the swap venue and the treasury vault are mocks. On X Layer mainnet those
                four are USDG, the xStocks wrappers, the existing pools and a tokenized treasury —
                the contract logic does not change, only addresses.
              </p>
            </div>
          </div>
        </div>

        <div className="grid content-start gap-4">
          <TapeStrip />
          <div className="card p-4 text-[12px] leading-relaxed text-inkdim">
            <p className="mb-2 text-[13px] font-semibold text-ink">Deployed</p>
            <p className="mono break-all">
              <a className="text-accent hover:underline" href={explorerAddr(ADDR.TipRouter)} target="_blank" rel="noreferrer">
                TipRouter
              </a>{" "}
              · X Layer testnet 1952
            </p>
          </div>
        </div>
      </div>
    </Chrome>
  );
}
