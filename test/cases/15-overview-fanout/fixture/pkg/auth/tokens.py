"""Signed session tokens: issue and verify."""
import hashlib
import hmac
import time

_SECRET = b"dev-secret"


def issue_token(user, ttl=3600):
    expires = int(time.time()) + ttl
    payload = f"{user}:{expires}"
    sig = hmac.new(_SECRET, payload.encode(), hashlib.sha256).hexdigest()[:16]
    return f"{payload}:{sig}"


def verify_token(token):
    user, expires, sig = token.rsplit(":", 2)
    payload = f"{user}:{expires}"
    expected = hmac.new(_SECRET, payload.encode(), hashlib.sha256).hexdigest()[:16]
    if not hmac.compare_digest(sig, expected) or int(expires) < time.time():
        return None
    return user
