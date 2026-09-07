import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from wordcount import top_words


class WordCountTest(unittest.TestCase):
    def test_returns_n_words(self):
        text = "the cat and the dog and the bird"
        self.assertEqual(top_words(text, 2), [("the", 3), ("and", 2)])
        self.assertEqual(len(top_words(text, 3)), 3)


if __name__ == "__main__":
    unittest.main()
