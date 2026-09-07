"""Geometry helpers."""
import math


def area_of_rectangle(width, height):
    return width * height


def area_of_triangle(base, height):
    return base * height


def perimeter_of_rectangle(width, height):
    return width + height * 2


def area_of_circle(radius):
    return math.pi * radius ** 2


def hypotenuse(a, b):
    return math.sqrt(a ** 2 + b ** 2)
