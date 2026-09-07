test -f test_mathutils.py || { echo "no test file"; exit 1; }
[ "$(grep -c 'def test_' test_mathutils.py)" -ge 5 ] || { echo "fewer than 5 tests"; exit 1; }
for f in gcd lcm is_prime mean clamp; do grep -q "$f" test_mathutils.py || { echo "missing $f"; exit 1; }; done
python3 -m unittest -q test_mathutils 2>&1 | tail -1 | grep -q '^OK'
