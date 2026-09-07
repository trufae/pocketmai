"""VAT rates by country code."""

RATES = {"ES": 21, "DE": 19, "FR": 20, "US": 0}


def vat_for(amount, country):
    return round(amount * RATES.get(country.upper(), 0) / 100, 2)
