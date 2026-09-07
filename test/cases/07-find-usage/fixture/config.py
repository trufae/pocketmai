import json


DEFAULTS = {"host": "127.0.0.1", "port": 8000, "workers": 2}


def parse_config(path):
    """Load a JSON config file and apply defaults."""
    with open(path) as fh:
        data = json.load(fh)
    merged = dict(DEFAULTS)
    merged.update(data)
    return merged


def validate(config):
    if not (0 < config["port"] < 65536):
        raise ValueError("port out of range")
    return config
