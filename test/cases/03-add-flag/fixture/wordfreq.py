#!/usr/bin/env python3
"""Print the most frequent words of a text file."""
import argparse
import collections
import re


def count_words(text):
    words = re.findall(r"[a-zA-Z']+", text.lower())
    return collections.Counter(words)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="text file to analyse")
    parser.add_argument("-n", "--top", type=int, default=10, help="how many words to show")
    args = parser.parse_args()
    with open(args.path) as fh:
        counts = count_words(fh.read())
    for word, count in counts.most_common(args.top):
        print(f"{word:15} {count}")


if __name__ == "__main__":
    main()
