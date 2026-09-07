# Read-only task: the answer must mention the key symbols and nothing may change.
grep -q "Inventory" "$STDOUT" && grep -q "format_report" "$STDOUT" && grep -q "low_stock" "$STDOUT"
