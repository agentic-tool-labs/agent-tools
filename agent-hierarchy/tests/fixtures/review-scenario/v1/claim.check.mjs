// The change's own claim as a check: "emitted events carry each item's real kind". It is not part of the suite
// (the suite runs only tests/test-*.sh); run it by hand with node. It exits non-zero while the claim is false.
import { emit, loadFromList } from "./items.mjs";

const record = { id: "a", expires: 5 };
const real = loadFromList(record).kind;
const emitted = emit(record).kind;
if (emitted !== real) {
  console.error(`claim does not hold: emitted ${emitted}, the list path says ${real}`);
  process.exit(1);
}
