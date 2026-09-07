import math
import unittest

import shapes


class ShapesTest(unittest.TestCase):
    def test_rectangle_area(self):
        self.assertEqual(shapes.area_of_rectangle(3, 4), 12)

    def test_triangle_area(self):
        self.assertEqual(shapes.area_of_triangle(3, 4), 6)

    def test_rectangle_perimeter(self):
        self.assertEqual(shapes.perimeter_of_rectangle(3, 4), 14)

    def test_circle_area(self):
        self.assertAlmostEqual(shapes.area_of_circle(1), math.pi)

    def test_hypotenuse(self):
        self.assertEqual(shapes.hypotenuse(3, 4), 5)


if __name__ == "__main__":
    unittest.main()
