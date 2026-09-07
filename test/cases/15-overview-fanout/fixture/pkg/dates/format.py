"""Relative wording for time differences."""


def humanize(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds} seconds ago"
    if seconds < 3600:
        return f"{seconds // 60} minutes ago"
    if seconds < 86400:
        return f"{seconds // 3600} hours ago"
    return f"{seconds // 86400} days ago"
