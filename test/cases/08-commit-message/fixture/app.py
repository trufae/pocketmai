import sys


def parse_age(text):
    return int(text)


def greet(name, age):
    return f"Hello {name}, you are {age} years old"


def main(argv):
    name, age = argv[1], parse_age(argv[2])
    print(greet(name, age))


if __name__ == "__main__":
    main(sys.argv)
