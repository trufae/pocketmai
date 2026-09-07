"""Invoice arithmetic over line items of (description, quantity, unit price)."""


def total_due(lines):
    return round(sum(quantity * price for _, quantity, price in lines), 2)


def apply_discount(amount, percent):
    if not 0 <= percent <= 100:
        raise ValueError("percent must be between 0 and 100")
    return round(amount * (100 - percent) / 100, 2)
