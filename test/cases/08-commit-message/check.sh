# nothing may be committed, and the message must be about validation
[ "$(git -C "$WORK" rev-list --count HEAD)" = "1" ] || { echo "a commit was made"; exit 1; }
grep -qi 'valid' "$STDOUT"
