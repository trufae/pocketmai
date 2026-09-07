from .io_utils import fetch_data


def normalize(rows):
    return [{k.strip().lower(): v.strip() for k, v in row.items()} for row in rows]


def load_and_normalize(path):
    return normalize(fetch_data(path))
