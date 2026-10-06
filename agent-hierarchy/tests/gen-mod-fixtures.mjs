// Prints mod/tests/fixtures.ts for the status fixtures in <dir>: case name (file name without .json)
// mapped to the file's exact text. The mod's tests read fixtures through it because `claude plugin test`
// loads only code files, never JSON.
// Usage: node tests/gen-mod-fixtures.mjs <tests/fixtures/status dir>
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.argv[2];
const cases = readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
let out = "// Generated from tests/fixtures/status/*.json by `AH_UPDATE_FIXTURES=1 bash tests/test-status-fixtures.sh`. Do not edit.\n";
out += "export const fixtures: Readonly<Record<string, string>> = {\n";
for (const f of cases) out += `  ${JSON.stringify(f.slice(0, -".json".length))}: ${JSON.stringify(readFileSync(join(dir, f), "utf8"))},\n`;
out += "}\n";
process.stdout.write(out);
