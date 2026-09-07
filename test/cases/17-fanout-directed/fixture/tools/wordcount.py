"""Most common words of a text: wordcount.py FILE [N]"""
import re
import sys
from collections import Counter


def top_words(text, n=3):
    words = re.findall(r"[a-z']+", text.lower())
    return Counter(words).most_common(n)[: n - 1]


if __name__ == "__main__":
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    for word, count in top_words(open(sys.argv[1]).read(), n):
        print(f"{count} {word}")
