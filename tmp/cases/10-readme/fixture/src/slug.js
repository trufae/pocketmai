const DIACRITICS = /[\u0300-\u036f]/g;

export function slugify(text, { separator = "-", maxLength = 80 } = {}) {
  const ascii = text.normalize("NFD").replace(DIACRITICS, "");
  const slug = ascii
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, separator)
    .replace(new RegExp(`^${separator}+|${separator}+$`, "g"), "");
  return slug.slice(0, maxLength);
}

export function isSlug(text) {
  return /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(text);
}
