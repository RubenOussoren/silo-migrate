// Page-memory snapshots for navigation only. Detail/approval reads never use this cache.
// Paths include the project, so a late read cannot populate another project's list.
export function createListCache(read, limit = 8, freshMs = 1000) {
  const entries = new Map();
  const entry = (path) => {
    if (!entries.has(path)) {
      while (entries.size >= limit) entries.delete(entries.keys().next().value);
      entries.set(path, { value: null, at: 0, pending: null });
    }
    return entries.get(path);
  };
  return {
    peek: (path) => entries.get(path)?.value || null,
    clear: () => entries.clear(),
    load(path) {
      const record = entry(path);
      if (record.pending) return record.pending;
      if (record.value && Date.now() - record.at < freshMs) return Promise.resolve(record.value);
      record.pending = Promise.resolve().then(() => read(path)).then((value) => {
        // A decision or project reset may have invalidated this in-flight read.
        if (entries.get(path) === record) { record.value = value; record.at = Date.now(); }
        return value;
      }).finally(() => { record.pending = null; });
      return record.pending;
    },
  };
}
