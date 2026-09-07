[ -f OVERVIEW.md ] || { echo "OVERVIEW.md missing"; exit 1; }
for pkg in auth billing cache dates; do
  grep -qi "$pkg" OVERVIEW.md || { echo "package $pkg not mentioned"; exit 1; }
done
grep -Eq "issue_token|verify_token|hash_password|check_password" OVERVIEW.md || { echo "no auth function"; exit 1; }
grep -Eq "total_due|apply_discount|vat_for" OVERVIEW.md || { echo "no billing function"; exit 1; }
grep -Eq "LRUCache|memoize" OVERVIEW.md || { echo "no cache function"; exit 1; }
grep -Eq "business_days|next_weekday|humanize" OVERVIEW.md || { echo "no dates function"; exit 1; }
