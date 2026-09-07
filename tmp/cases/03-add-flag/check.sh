python3 wordfreq.py sample.txt --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, dict) and d.get("the")==5, d' || exit 1
grep -q -- '--json' README.md
