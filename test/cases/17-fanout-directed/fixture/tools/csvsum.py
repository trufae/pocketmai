"""Sum one column of a CSV file: csvsum.py FILE COLUMN"""
import csv
import sys


def column_sum(path, column):
    with open(path, newline="") as fh:
        rows = list(csv.DictReader(fh))
    total = 0.0
    for row in rows[1:]:
        total += float(row[column])
    return total


if __name__ == "__main__":
    print(column_sum(sys.argv[1], sys.argv[2]))
