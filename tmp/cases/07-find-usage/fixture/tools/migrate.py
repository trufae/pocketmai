import sys
sys.path.insert(0, "..")
from config import parse_config


def main(argv):
    old = parse_config(argv[1])
    old["workers"] = max(old["workers"], 4)
    print(old)


if __name__ == "__main__":
    main(sys.argv)
