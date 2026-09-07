cmp -s api/test_calc.py "$FIXTURE/api/test_calc.py" || { echo "api tests were modified"; exit 1; }
cmp -s web/check.js "$FIXTURE/web/check.js" || { echo "web check was modified"; exit 1; }
(cd api && python3 -m unittest -q test_calc 2>&1 | tail -1 | grep -q '^OK') || { echo "api tests fail"; exit 1; }
node web/check.js >/dev/null 2>&1 || { echo "web check fails"; exit 1; }
