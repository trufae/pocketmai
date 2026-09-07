"""Tiny price calculator used by the API."""


def line_total(quantity, unit_price):
    return quantity * unit_price


def order_total(lines, shipping=0.0):
    subtotal = sum(line_total(q, p) for q, p in lines)
    if subtotal > 100:
        shipping = 0.0
    return round(subtotal - shipping, 2)
