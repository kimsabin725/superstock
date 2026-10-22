// Copy deployments into web/ so the frontend never points at stale contracts.
import { copyFileSync, readFileSync } from "node:fs";
const src = "deployments.1952.json";
const dst = "web/lib/deployments.json";
copyFileSync(src, dst);
const d = JSON.parse(readFileSync(src, "utf8"));
console.log(`synced ${Object.keys(d).filter((k) => !k.startsWith("_")).length} addresses -> ${dst}`);
console.log(`  TipRouter ${d.TipRouter}`);
