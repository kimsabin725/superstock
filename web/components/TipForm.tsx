"use client";

import { useState } from "react";
import { useAccount, useChainId, useReadContract, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { parseUnits, maxUint256 } from "viem";
import { ABI, ADDR, REASONS } from "@/lib/chain";
import { id, usd, useCreatorAccount, useTape, TICKER_BY_ID } from "@/lib/hooks";
import { xlayerTestnet } from "@/lib/chain";
import { TapeStrip } from "./TapeStrip";
import { FanCard } from "./FanCard";

const PRESETS = [2, 5, 20, 50];

function toUnits(amount: string): bigint {
  try {
    return parseUnits(amount || "0", 6);
  } catch {
    return 0n;
  }
}

export function TipForm({ handle }: { handle: string }) {
  const { address, isConnected } = useAccount();
  const { account, loading } = useCreatorAccount(handle);
  const tape = useTape();

  const [amount, setAmount] = useState("5");
  const [message, setMessage] = useState("");
  const [choice, setChoice] = useState(0);
  const [sent, setSent] = useState<{ hash: `0x${string}`; amount: string; pick: string } | null>(null);

  const { data: portfolio } = useReadContract({
    address: account,
    abi: ABI.CreatorAccount,
    functionName: "portfolio",
    query: { enabled: !!account },
  });
  const [symbolIds, weights] = (portfolio as readonly [readonly `0x${string}`[], readonly number[]] | undefined) ?? [[], []];
  const tickers = symbolIds.map((s) => TICKER_BY_ID[s.toLowerCase()] ?? "?");

  const { data: balance } = useReadContract({
    address: ADDR.USDG,
    abi: ABI.MockERC20,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 5000 },
  });

  const { data: allowance } = useReadContract({
    address: ADDR.USDG,
    abi: ABI.MockERC20,
    functionName: "allowance",
    args: address ? [address, ADDR.TipRouter] : undefined,
    query: { enabled: !!address, refetchInterval: 5000 },
  });

  const units = toUnits(amount);

  // Until the allowance has actually been read, we do not know which button to
  // show — offering "Tip" on an unknown allowance just sends a tip that reverts.
  const allowanceKnown = allowance !== undefined;
  const needsApproval = allowanceKnown && (allowance as bigint) < units;
  const chainId = useChainId();
  const wrongChain = isConnected && chainId !== xlayerTestnet.id;
  const { writeContract, isPending, error } = useWriteContract();
  const { isLoading: mining } = useWaitForTransactionReceipt({ hash: sent?.hash });

  const pickLabel = choice === 0 ? "their plan" : tickers[choice - 1] ?? "?";
  const heldNames = choice === 0 ? tickers : [tickers[choice - 1]];
  const holding = heldNames.filter((t) => tape[t] && !tape[t].allow);

  function mint() {
    writeContract({
      address: ADDR.USDG,
      abi: ABI.MockERC20,
      functionName: "mint",
      args: [address!, parseUnits("500", 6)],
    });
  }

  function approve() {
    writeContract({
      address: ADDR.USDG,
      abi: ABI.MockERC20,
      functionName: "approve",
      args: [ADDR.TipRouter, maxUint256],
    });
  }

  function tip() {
    writeContract(
      {
        address: ADDR.TipRouter,
        abi: ABI.TipRouter,
        functionName: "tip",
        args: [id("orbit"), id(handle), units, id(message || " "), choice],
      },
      { onSuccess: (hash) => setSent({ hash, amount, pick: pickLabel }) },
    );
  }

  if (loading) {
    return <div className="card p-6 text-[14px] text-inkdim">Looking up {handle}…</div>;
  }

  if (!account) {
    return (
      <div className="card p-6 text-[14px] text-inkdim">
        <span className="mono text-ink">{handle}</span> has not set up an account yet.
      </div>
    );
  }

  return (
    <div className="grid grid-cols-1 gap-6 md:grid-cols-[minmax(0,1fr)_320px]">
      <div className="grid min-w-0 grid-cols-1 gap-5">
        <div>
          <p className="text-[12.5px] uppercase tracking-wider text-inkdim">Support</p>
          <h1 className="mono mt-1 text-[26px] font-semibold">{handle}</h1>
          <p className="mt-2 max-w-md text-[14px] leading-relaxed text-inkdim">
            Your tip doesn&apos;t arrive as cash. It arrives as the stock they chose to be paid in —
            bought at the market price, in their own account, in the same transaction.
          </p>
        </div>

        <div className="card p-5">
          <label htmlFor="tip-amount" className="text-[12.5px] text-inkdim">Amount</label>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <div className="flex items-center rounded-lg border border-line bg-panel2 px-3">
              <span className="text-inkdim">$</span>
              <input
                id="tip-amount"
                aria-label="Tip amount in US dollars"
                className="w-28 border-0 bg-transparent px-2 py-2.5 text-[18px] font-semibold"
                value={amount}
                onChange={(e) => { setSent(null); setAmount(e.target.value.replace(/[^0-9.]/g, "")); }}
                inputMode="decimal"
              />
            </div>
            {PRESETS.map((p) => (
              <button key={p} className="btn-ghost px-3 py-2 text-[13px]" onClick={() => { setSent(null); setAmount(String(p)); }}>
                ${p}
              </button>
            ))}
          </div>

          <label htmlFor="tip-message" className="mt-5 block text-[12.5px] text-inkdim">Message</label>
          <input
            id="tip-message"
            className="mt-2 w-full px-3 py-2.5 text-[14px]"
            placeholder="say something"
            maxLength={120}
            value={message}
            onChange={(e) => { setSent(null); setMessage(e.target.value); }}
          />

          <label className="mt-5 block text-[12.5px] text-inkdim">Buy them</label>
          <div className="mt-2 flex flex-wrap gap-2">
            <button
              className={choice === 0 ? "btn px-3 py-2 text-[13px]" : "btn-ghost px-3 py-2 text-[13px]"}
              onClick={() => setChoice(0)}
            >
              Their plan{" "}
              <span className="opacity-70">
                ({tickers.map((t, i) => `${t} ${(weights[i] ?? 0) / 100}%`).join(" · ")})
              </span>
            </button>
            {tickers.map((t, i) => (
              <button
                key={t}
                className={choice === i + 1 ? "btn px-3 py-2 text-[13px]" : "btn-ghost px-3 py-2 text-[13px]"}
                onClick={() => setChoice(i + 1)}
              >
                {t}
              </button>
            ))}
          </div>

          {holding.length > 0 && (
            <p className="mt-4 rounded-lg bg-panel2 px-3 py-2.5 text-[12.5px] text-hold">
              {holding.map((t) => `${t}: ${REASONS[tape[t].reason] ?? tape[t].reason}`).join(" · ")} — your tip still
              goes through now; the cash waits in their account and buys at the next open.
            </p>
          )}

          <div className="mt-5 flex flex-wrap items-center gap-3">
            {!isConnected ? (
              <span className="text-[13px] text-inkdim">Connect a wallet to tip.</span>
            ) : wrongChain ? (
              <span className="text-[13px] text-hold">Switch to X Layer testnet to tip.</span>
            ) : !allowanceKnown ? (
              <span className="text-[13px] text-inkdim">Checking your allowance…</span>
            ) : needsApproval ? (
              <button className="btn px-4 py-2.5 text-[14px]" disabled={isPending} onClick={approve}>
                Allow USDG
              </button>
            ) : (
              <button
                className="btn px-4 py-2.5 text-[14px]"
                disabled={isPending || mining || units === 0n}
                onClick={tip}
              >
                {isPending || mining ? "Sending…" : `Tip $${amount || "0"}`}
              </button>
            )}
            {isConnected && (
              <>
                <span className="text-[12.5px] text-inkdim">
                  balance ${usd(balance as bigint | undefined)}
                </span>
                <button className="btn-ghost px-3 py-2 text-[12px]" onClick={mint}>
                  Get test USDG
                </button>
              </>
            )}
          </div>
        </div>

        {error && (
          <p className="text-[12.5px] text-hold">{error.message.split("\n")[0]}</p>
        )}

        {sent && <FanCard handle={handle} amount={sent.amount} pick={sent.pick} hash={sent.hash} message={message} />}
      </div>

      <div className="grid content-start gap-4">
        <TapeStrip only={tickers} />
        <div className="card p-4 text-[12px] leading-relaxed text-inkdim">
          <p className="mb-2 text-[13px] font-semibold text-ink">Where the money goes</p>
          <p>
            The platform&apos;s cut leaves as stablecoin in the same transaction. The rest lands in
            {" "}<a className="mono text-accent" href={`https://www.oklink.com/x-layer-testnet/address/${account}`} target="_blank" rel="noreferrer">
              {account.slice(0, 8)}…{account.slice(-6)}
            </a>
            {" "}— an account only this creator can withdraw from.
          </p>
        </div>
      </div>
    </div>
  );
}
