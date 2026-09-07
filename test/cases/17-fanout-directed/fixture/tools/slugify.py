"""Turn a title into a URL slug: slugify.py TITLE"""
import re
import sys


def slugify(title):
    slug = title.strip().lower()
    slug = re.sub(r"[^a-z0-9]+", "_", slug)
    return slug.strip("-")


if __name__ == "__main__":
    print(slugify(" ".join(sys.argv[1:])))
