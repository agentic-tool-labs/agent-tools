// Change 1: emit adds the item's kind, taken from the single-item loader.

const KNOWN_KINDS = new Set(["permanent", "temporary", "archived"]);

// List path: infers the kind from other fields when the record carries none.
export function loadFromList(record) {
  const kind = record.kind ?? (record.expires !== undefined ? "temporary" : "permanent");
  return { id: record.id, kind };
}

// Single-item path: an absent kind is "unspecified", and so is a value it does not recognise (with a reason).
export function loadOne(record) {
  if (record.kind === undefined) return { id: record.id, kind: "unspecified" };
  if (!KNOWN_KINDS.has(record.kind)) return { id: record.id, kind: "unspecified", reason: "unrecognized" };
  return { id: record.id, kind: record.kind };
}

// Emitted events carry each item's real kind.
export function emit(record) {
  const item = loadOne(record);
  return { id: item.id, kind: item.kind, ...(item.reason && { reason: item.reason }) };
}
