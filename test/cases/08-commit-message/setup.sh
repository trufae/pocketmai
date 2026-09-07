git init -q
git config user.email bench@example.com
git config user.name bench
git add -A
git commit -qm "Initial import"
python3 - <<'PY'
import re
src = open("app.py").read()
src = src.replace('''def parse_age(text):
    return int(text)''', '''def parse_age(text):
    try:
        age = int(text)
    except ValueError:
        raise SystemExit(f"error: age must be a number, got {text!r}")
    if age < 0 or age > 150:
        raise SystemExit(f"error: age out of range: {age}")
    return age''')
src = src.replace('''    name, age = argv[1], parse_age(argv[2])''', '''    if len(argv) != 3:
        raise SystemExit("usage: app.py NAME AGE")
    name, age = argv[1], parse_age(argv[2])''')
open("app.py", "w").write(src)
readme = open("README.md").read() + "\nThe age must be a number between 0 and 150.\n"
open("README.md", "w").write(readme)
PY
