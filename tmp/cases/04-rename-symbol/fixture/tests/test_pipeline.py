import os
import tempfile
import unittest

from pipeline import fetch_data, normalize
from pipeline.transform import load_and_normalize


class PipelineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False)
        self.tmp.write(" Name , City \n Ana , Lisbon \n")
        self.tmp.close()

    def tearDown(self):
        os.unlink(self.tmp.name)

    def test_fetch_data(self):
        rows = fetch_data(self.tmp.name)
        self.assertEqual(len(rows), 1)

    def test_normalize(self):
        rows = normalize(fetch_data(self.tmp.name))
        self.assertEqual(rows[0]["name"], "Ana")

    def test_load_and_normalize(self):
        self.assertEqual(load_and_normalize(self.tmp.name)[0]["city"], "Lisbon")
