import { defineChain, type Abi } from "viem";
import addresses from "./deployments.json";
import abis from "./abis.json";

export const xlayerTestnet = defineChain({
  id: 1952,
  name: "X Layer Testnet",
  nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
  rpcUrls: { default: { http: ["https://testrpc.xlayer.tech"] } },
  blockExplorers: {
    default: { name: "OKLink", url: "https://www.oklink.com/x-layer-testnet" },
  },
  testnet: true,
});

export const ADDR = addresses as unknown as Record<string, `0x${string}`>;
export const ABI = abis as unknown as Record<string, Abi>;

export const POOL = ["NVDAx", "TSLAx", "SPYx", "AAPLx", "COINx"] as const;
export type Ticker = (typeof POOL)[number];

export const explorerTx = (hash: string) =>
  `https://www.oklink.com/x-layer-testnet/tx/${hash}`;
export const explorerAddr = (a: string) =>
  `https://www.oklink.com/x-layer-testnet/address/${a}`;

/** Reason codes the account layer reports, straight from the shared table. */
export const REASONS: Record<number, string> = {
  0: "Market open",
  100: "Underlying market closed",
  101: "Extended hours",
  102: "Exchange lunch break",
  110: "Session unknown",
  200: "Halted — news pending",
  201: "Halted — volatility",
  202: "Halted — regulatory",
  203: "Halted — market wide",
  210: "Halted by the issuer",
  220: "Halted — uncategorised",
  300: "Corporate action window",
  400: "Price went stale",
  402: "No price available",
  900: "Signal feed went quiet",
};
