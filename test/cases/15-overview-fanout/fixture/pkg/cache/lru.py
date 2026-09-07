"""A small least-recently-used cache and a decorator built on it."""
from collections import OrderedDict
from functools import wraps


class LRUCache:
    def __init__(self, capacity=128):
        self.capacity = capacity
        self._items = OrderedDict()

    def get(self, key, default=None):
        if key not in self._items:
            return default
        self._items.move_to_end(key)
        return self._items[key]

    def put(self, key, value):
        self._items[key] = value
        self._items.move_to_end(key)
        while len(self._items) > self.capacity:
            self._items.popitem(last=False)


def memoize(capacity=128):
    cache = LRUCache(capacity)

    def decorator(fn):
        @wraps(fn)
        def wrapper(*args):
            hit = cache.get(args)
            if hit is None:
                hit = fn(*args)
                cache.put(args, hit)
            return hit
        return wrapper
    return decorator
