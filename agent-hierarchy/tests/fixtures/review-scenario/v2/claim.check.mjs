// The change's own claim as a check: an item without a kind gets its real kind, and nothing else changes.
// Not part of the suite; run it by hand with node. It exits non-zero while a case is wrong.
import { emit, loadOne } from "./items.mjs";

const cases = [
  { name: "temporary item without a kind", record: { id: "a", expires: 5, storedKind: "temporary" }, want: { id: "a", kind: "temporary" } },
  { name: "unrecognised kind keeps its reason", record: { id: "b", kind: "bogus", storedKind: "archived" }, want: loadOne({ id: "b", kind: "bogus" }) },
  { name: "non-temporary item without a kind", record: { id: "c", storedKind: "archived" }, want: { id: "c", kind: "unspecified" } },
];
let bad = 0;
for (const c of cases) {
  const got = JSON.stringify(emit(c.record)), want = JSON.stringify(c.want);
  if (got !== want) { bad++; console.error(`${c.name}: got ${got}, want ${want}`); }
}
process.exit(bad ? 1 : 0);
