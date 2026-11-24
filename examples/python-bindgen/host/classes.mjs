// The `workers.classes` sections a module declares its classes in, for
// package.mjs.

// Combines `workers.classes` texts. Each text is one JSON object, or several
// one per line, so a compiler can emit a fragment per export and let the
// linker concatenate them into one section. Fragments for the same class merge: methods are
// unioned, and other fields must agree. A fragment without a `kind` only adds
// methods to a class another fragment declares; a class that no fragment
// gives a kind is not a class of the Worker, and is dropped.
export function mergeClasses(texts) {
  const classes = {};
  for (const text of texts) {
    for (const fragment of jsonFragments(text)) {
      for (const [name, info] of Object.entries(fragment)) {
        const prev = classes[name];
        if (!prev) {
          classes[name] = { ...info, ...(info.methods ? { methods: [...info.methods] } : {}) };
          continue;
        }
        for (const [k, v] of Object.entries(info)) {
          if (k === "methods") prev.methods = [...new Set([...(prev.methods ?? []), ...v])];
          else if (prev[k] === undefined) prev[k] = v;
          else if (prev[k] !== v) throw new TypeError(`workers.classes: ${name} has conflicting ${k}: ${prev[k]} and ${v}`);
        }
      }
    }
  }
  for (const [name, info] of Object.entries(classes)) {
    if (info.kind === undefined) delete classes[name];
  }
  return classes;
}

// One JSON value, or JSON values one per line.
export function jsonFragments(text) {
  try {
    return [JSON.parse(text)];
  } catch {
    return text.split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
  }
}
