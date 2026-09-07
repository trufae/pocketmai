"""Salted password hashing."""
import hashlib
import os


def hash_password(password, salt=None):
    salt = salt or os.urandom(8).hex()
    digest = hashlib.sha256((salt + password).encode()).hexdigest()
    return f"{salt}${digest}"


def check_password(password, stored):
    salt, _ = stored.split("$", 1)
    return hash_password(password, salt) == stored
