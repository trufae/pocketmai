"""Calendar arithmetic without external libraries."""
from datetime import date, timedelta


def business_days(start, end):
    days = 0
    current = start
    while current <= end:
        if current.weekday() < 5:
            days += 1
        current += timedelta(days=1)
    return days


def next_weekday(start, weekday):
    ahead = (weekday - start.weekday()) % 7 or 7
    return start + timedelta(days=ahead)
