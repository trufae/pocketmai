import sys
from config import parse_config, validate


def start_server(path):
    config = validate(parse_config(path))
    print(f"listening on {config['host']}:{config['port']} with {config['workers']} workers")


def stop_server():
    print("bye")


if __name__ == "__main__":
    start_server(sys.argv[1])
