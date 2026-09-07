const assert = require("assert");
const { formatPrice, cartSummary } = require("./app");

assert.strictEqual(formatPrice(1999), "$19.99");
assert.strictEqual(
  cartSummary([{ quantity: 2, priceCents: 500 }, { quantity: 1, priceCents: 999 }]),
  "3 items, $19.99"
);
console.log("web ok");
