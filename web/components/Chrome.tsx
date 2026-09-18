"use client";

import Link from "next/link";
import { useAccount, useConnect, useDisconnect, useChainId, useSwitchChain } from "wagmi";
import { xlayerTestnet } from "@/lib/chain";

export function Chrome({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen">
      <header className="border-b border-line">
        <div className="mx-auto flex max-w-5xl items-center gap-6 px-5 py-4">
          <Link href="/" className="text-[15px] font-semibold tracking-tight">
            Super<span className="text-accent">Stock</span>
          </Link>
          <nav className="flex gap-5 text-[13px] text-inkdim">
            <Link className="hover:text-ink" href="/c/@indiemusician">Tip page</Link>
            <Link className="hover:text-ink" href="/dashboard/@indiemusician">Creator</Link>
            <Link className="hover:text-ink" href="/platform">Platform</Link>
          </nav>
          <div className="ml-auto"><Wallet /></div>
        </div>
      </header>
      <main className="mx-auto max-w-5xl px-5 py-8">{children}</main>
    </div>
  );
}

export function Wallet() {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();

  if (!isConnected) {
    const c = connectors[0];
    return (
      <button
        className="btn px-3.5 py-2 text-[13px]"
        disabled={!c || isPending}
        onClick={() => c && connect({ connector: c })}
      >
        {isPending ? "Connecting…" : "Connect wallet"}
      </button>
    );
  }

  if (chainId !== xlayerTestnet.id) {
    return (
      <button
        className="btn px-3.5 py-2 text-[13px]"
        onClick={() => switchChain({ chainId: xlayerTestnet.id })}
      >
        Switch to X Layer
      </button>
    );
  }

  return (
    <button
      className="btn-ghost mono px-3 py-2 text-[12px]"
      onClick={() => disconnect()}
      title="Disconnect"
    >
      {address?.slice(0, 6)}…{address?.slice(-4)}
    </button>
  );
}
