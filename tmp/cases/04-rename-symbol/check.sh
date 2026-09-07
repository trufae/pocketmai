if grep -r "fetch_data" --exclude-dir=.pmai --exclude-dir=__pycache__ . ; then echo "fetch_data still present"; exit 1; fi
grep -rq "load_records" pipeline/io_utils.py docs/API.md || exit 1
python3 -m unittest discover -s tests -t . -q 2>&1 | tail -1 | grep -q '^OK'
