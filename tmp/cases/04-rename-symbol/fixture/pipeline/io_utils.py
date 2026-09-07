import csv


def fetch_data(path):
    """Read a CSV file and return a list of row dictionaries."""
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def write_data(path, rows):
    if not rows:
        return
    with open(path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
