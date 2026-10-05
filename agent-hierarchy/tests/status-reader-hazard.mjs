import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const LIB = join(fileURLToPath(import.meta.url), "..", "..", "hooks", "lib-status.mjs");
const REC = JSON.stringify({ activity: "working", at: "2026-01-01T00:00:00.000Z", blocked_by: null, note: null }) + "\n";
const mkfifo = (p) => execFileSync("mkfifo", [p]);
const isReg = (p) => lstatSync(p).isFile();

// Each case gets a fresh hierarchy dir `d` with activity/ and a scratch `other` dir.
const cases = {
  // recordActivity returns false when an identical record exists, true when it finds none and writes.
  H1: async ({ d, other, lib }) => { writeFileSync(join(other, "r"), REC); symlinkSync(join(other, "r"), join(d, "activity", "s.json")); return lib.recordActivity(d, "s", { activity: "working" }) === true; },
  H2: async ({ d, lib }) => { mkfifo(join(d, "activity", "s.json")); return lib.recordActivity(d, "s", { activity: "working" }) === true; },
  H3: async ({ d, lib }) => { mkdirSync(join(d, "activity", "s.json")); const wrote = lib.recordActivity(d, "s", { activity: "working" }); return wrote === false && lstatSync(join(d, "activity", "s.json")).isDirectory(); },
  H4: async ({ d, lib }) => { writeFileSync(join(d, "activity", "s.json"), ""); return lib.recordActivity(d, "s", { activity: "working" }) === true; },
  H5: async ({ d, lib }) => {
    const base = { activity: "working", at: "x", blocked_by: null, note: null, pad: "" };
    const room = 4097 - (JSON.stringify(base).length + 1);
    base.pad = "p".repeat(room);
    const text = JSON.stringify(base) + "\n";
    if (text.length !== 4097) return false;
    writeFileSync(join(d, "activity", "s.json"), text);
    return lib.recordActivity(d, "s", { activity: "working" }) === true;
  },
  H6: async ({ d, lib }) => { writeFileSync(join(d, "activity", "s.json"), REC); return lib.recordActivity(d, "s", { activity: "working" }) === false; },
  H7: async ({ d, other, lib }) => {
    rmSync(join(d, "activity"), { recursive: true });
    writeFileSync(join(other, "x.json"), REC);
    symlinkSync(other, join(d, "activity"));
    const old = new Date(2000, 0, 1);
    (await import("node:fs")).utimesSync(join(other, "x.json"), old, old);
    const swept = lib.sweepActivity(d, Date.now());
    const wrote = lib.recordActivity(d, "s", { activity: "working" });
    return swept === 0 && existsSync(join(other, "x.json")) && wrote === false && !existsSync(join(other, "s.json"));
  },
  W1: async ({ d, other, lib }) => {
    writeFileSync(join(other, "t"), "KEEP\n");
    symlinkSync(join(other, "t"), join(d, `status.json.${process.pid}.tmp`));
    lib.saveStatus(d, { a: 1 });
    return readFileSync(join(other, "t"), "utf8") === "KEEP\n" && isReg(join(d, "status.json")) && readFileSync(join(d, "status.json"), "utf8") === '{"a":1}\n';
  },
  W2: async ({ d, other, lib }) => {
    writeFileSync(join(other, "t"), "KEEP\n");
    symlinkSync(join(other, "t"), join(d, "activity", `s.json.${process.pid}.tmp`));
    const wrote = lib.recordActivity(d, "s", { activity: "working" });
    return wrote === true && readFileSync(join(other, "t"), "utf8") === "KEEP\n" && isReg(join(d, "activity", "s.json"));
  },
  W3: async ({ d, other, lib }) => {
    writeFileSync(join(other, "t"), "KEEP\n");
    symlinkSync(join(other, "t"), join(d, "status.json"));
    lib.saveStatus(d, { a: 1 });
    return isReg(join(d, "status.json")) && readFileSync(join(other, "t"), "utf8") === "KEEP\n";
  },
  W4: async ({ d, lib }) => { mkfifo(join(d, "status.json")); lib.saveStatus(d, { a: 1 }); return isReg(join(d, "status.json")); },
  W5: async ({ d, lib }) => { writeFileSync(join(d, `status.json.${process.pid}.tmp`), "stale"); lib.saveStatus(d, { a: 1 }); return readFileSync(join(d, "status.json"), "utf8") === '{"a":1}\n'; },
};

const name = process.argv[2];
if (name) {
  const root = mkdtempSync(join(tmpdir(), "ah-hazard-"));
  if (!root) process.exit(2);
  const d = join(root, "hier"), other = join(root, "other");
  mkdirSync(join(d, "activity"), { recursive: true });
  mkdirSync(other);
  let ok = false;
  try { ok = await cases[name]({ d, other, lib: await import(LIB) }); } catch (e) { console.error(e); }
  rmSync(root, { recursive: true, force: true });
  process.exit(ok ? 0 : 1);
}

let fail = 0;
for (const n of Object.keys(cases)) {
  const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url), n], { timeout: 10000, encoding: "utf8" });
  const ok = r.status === 0;
  if (!ok) fail++;
  console.log(`${ok ? "PASS" : "FAIL"}: ${n}${r.error ? " (timeout)" : ""}`);
}
console.log(`${Object.keys(cases).length - fail} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
