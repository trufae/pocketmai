import json
import tempfile
import unittest

from config import parse_config


class ConfigTest(unittest.TestCase):
    def test_defaults_applied(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"port": 9000}, fh)
        config = parse_config(fh.name)
        self.assertEqual(config["port"], 9000)
        self.assertEqual(config["host"], "127.0.0.1")
