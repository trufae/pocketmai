import unittest

from calc import line_total, order_total


class CalcTest(unittest.TestCase):
    def test_line_total(self):
        self.assertEqual(line_total(3, 2.5), 7.5)

    def test_order_total_adds_shipping(self):
        self.assertEqual(order_total([(1, 20.0), (2, 10.0)], shipping=5.0), 45.0)

    def test_free_shipping_over_100(self):
        self.assertEqual(order_total([(2, 60.0)], shipping=5.0), 120.0)


if __name__ == "__main__":
    unittest.main()
