cmp -s test_shapes.py "$FIXTURE/test_shapes.py" || { echo "tests were modified"; exit 1; }
python3 -m unittest -q test_shapes 2>&1 | tail -1 | grep -q '^OK'
