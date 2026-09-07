python3 app.py --version | grep -q '1\.1\.0' || { echo "--version failed"; exit 1; }
python3 app.py Ana | grep -q 'Hello, Ana!' || { echo "greeting wrong"; exit 1; }
grep -q '__version__ = "1.1.0"' app.py
