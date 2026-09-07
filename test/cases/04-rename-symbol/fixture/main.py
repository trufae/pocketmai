import sys
from pipeline import fetch_data, normalize
from pipeline.io_utils import write_data


def main(argv):
    rows = normalize(fetch_data(argv[1]))
    write_data(argv[2], rows)
    print(f"wrote {len(rows)} rows")


if __name__ == "__main__":
    main(sys.argv)
