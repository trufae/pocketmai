import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from slugify import slugify


class SlugifyTest(unittest.TestCase):
    def test_hyphenates_words(self):
        self.assertEqual(slugify("Hello, World!"), "hello-world")
        self.assertEqual(slugify("  Two  spaces "), "two-spaces")


if __name__ == "__main__":
    unittest.main()
