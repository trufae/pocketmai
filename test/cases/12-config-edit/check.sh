python3 - "$FIXTURE/config.json" <<'PY'
import json, sys
new = json.load(open("config.json"))
old = json.load(open(sys.argv[1]))
assert new["server"]["port"] == 8080, new["server"]
assert new.get("debug") is False, new.get("debug")
old["server"]["port"] = 8080
old["debug"] = False
assert new == old, "other keys changed"
print("ok")
PY
