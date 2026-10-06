// Base snapshot: two loaders for the same item record, and an emit that reports only the id.

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

export function emit(record) {
  const item = loadOne(record);
  return { id: item.id };
}
