make -s >/dev/null 2>&1 || { echo "make failed"; exit 1; }
./app | grep -q 'sum = 15'
