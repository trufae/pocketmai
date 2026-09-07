import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from csvsum import column_sum


class CsvSumTest(unittest.TestCase):
    def test_sums_every_data_row(self):
        with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False) as fh:
            fh.write("name,amount\na,1.5\nb,2\nc,3.5\n")
            path = fh.name
        self.assertEqual(column_sum(path, "amount"), 7.0)
        os.unlink(path)


if __name__ == "__main__":
    unittest.main()
