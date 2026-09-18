// The web app ships the deployment it was built against. Copying by hand is how
// a frontend ends up pointing at contracts nobody deployed any more.
import { copyFileSync, readFileSync } from "node:fs";
const src = "deployments.1952.json";
const dst = "web/lib/deployments.json";
copyFileSync(src, dst);
const d = JSON.parse(readFileSync(src, "utf8"));
console.log(`synced ${Object.keys(d).filter((k) => !k.startsWith("_")).length} addresses -> ${dst}`);
console.log(`  TipRouter ${d.TipRouter}`);
