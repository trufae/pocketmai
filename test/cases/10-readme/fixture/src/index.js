export { slugify, isSlug } from "./slug.js";

export function uniqueSlug(text, taken, options) {
  const base = slugify(text, options);
  let candidate = base;
  let n = 2;
  while (taken.includes(candidate)) {
    candidate = `${base}-${n++}`;
  }
  return candidate;
}

import { slugify } from "./slug.js";
