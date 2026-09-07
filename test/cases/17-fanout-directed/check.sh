for t in csvsum wordcount slugify; do
  cmp -s "tests/test_$t.py" "$FIXTURE/tests/test_$t.py" || { echo "tests/test_$t.py was modified"; exit 1; }
  python3 "tests/test_$t.py" >/dev/null 2>&1 || { echo "test_$t fails"; exit 1; }
done
