// Formats a shopping cart for display.
function formatPrice(cents) {
  return "$" + (cents / 100).toFixed(2);
}

function cartSummary(items) {
  const count = items.reduce((n, item) => n + item.quantity, 0);
  const total = items.reduce((sum, item) => sum + item.quantity * item.priceCents, 0);
  return `${count} items, ${formatPrice(totl)}`;
}

module.exports = { formatPrice, cartSummary };
