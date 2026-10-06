// Change 2: when the loaded kind is "unspecified", substitute the item's stored kind.

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

// Emitted events carry each item's real kind; an unspecified kind falls back to the stored one.
export function emit(record) {
  let item = loadOne(record);
  if (item.kind === "unspecified") item = { id: item.id, kind: record.storedKind ?? item.kind };
  return { id: item.id, kind: item.kind, ...(item.reason && { reason: item.reason }) };
}
