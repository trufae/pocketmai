import sys


def greeting(name):
    return f"Helo, {name}!"


def main(argv):
    name = argv[1] if len(argv) > 1 else "world"
    print(greeting(name))


if __name__ == "__main__":
    main(sys.argv)
