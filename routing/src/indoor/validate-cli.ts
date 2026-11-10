/** Validate every routing/buildings/*.json file. Exits 1 on any problem. */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { BuildingGraph } from "./types";
import { validateBuilding } from "./validate";

const dir = join(import.meta.dir, "..", "..", "buildings");
let failed = false;
for (const file of readdirSync(dir).filter((f) => f.endsWith(".json"))) {
  const g = JSON.parse(readFileSync(join(dir, file), "utf8")) as BuildingGraph;
  const errors = validateBuilding(g);
  console.log(`${errors.length ? "✗" : "✓"} ${file}${g.verified ? "" : " (unverified)"}`);
  for (const e of errors) console.log(`    ${e}`);
  failed ||= errors.length > 0;
}
process.exit(failed ? 1 : 0);
