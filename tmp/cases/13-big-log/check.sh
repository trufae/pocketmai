count=$(sed -n 1p "$FIXTURE/../expected.txt"); msg=$(sed -n 2p "$FIXTURE/../expected.txt")
grep -q "$count" "$STDOUT" && grep -qi "$msg" "$STDOUT"
