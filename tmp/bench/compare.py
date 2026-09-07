#!/usr/bin/env python3
"""Compare runs side by side: tokens, calls, time, outcome, per case and in total.

Usage:
  python3 tmp/bench/compare.py tmp/results/<run-a> tmp/results/<run-b> [...]

Per case it prints solved/failed, model calls, prompt and completion tokens,
wall time and the median latency of a model call. For runs in tool-proxy mode
it also counts list-tools calls and the characters their results added to the
context, and tool results that were errors.
"""
import json
import statistics
import sys
from pathlib import Path


def text_of(content):
    if isinstance(content, str):
        return content
    return "".join(p.get("text", "") for p in content or [] if isinstance(p, dict))


def case_stats(case_dir):
    meta = json.loads((case_dir / "meta.json").read_text())
    calls = []
    log = case_dir / "proxy.jsonl"
    if log.exists():
        for line in open(log):
            try:
                calls.append(json.loads(line))
            except Exception:
                pass
    prompt = completion = 0
    latencies = []
    list_calls = 0
    list_chars = 0
    errors = 0
    seen_ids = set()
    for c in calls:
        u = (c.get("response") or {}).get("usage") or {}
        prompt += u.get("prompt_tokens", 0)
        completion += u.get("completion_tokens", 0)
        latencies.append(c.get("elapsed") or 0)
        for tc in (c.get("response") or {}).get("tool_calls") or []:
            if tc.get("name") == "list-tools":
                list_calls += 1
        # tool results as the next request saw them
        msgs = (c.get("request") or {}).get("messages") or []
        names = {}
        for m in msgs:
            if m.get("role") == "assistant":
                for tc in m.get("tool_calls") or []:
                    names[tc.get("id")] = (tc.get("function") or {}).get("name")
        for m in msgs:
            if m.get("role") == "tool" and m.get("tool_call_id") not in seen_ids:
                seen_ids.add(m.get("tool_call_id"))
                t = text_of(m.get("content"))
                if names.get(m.get("tool_call_id")) == "list-tools":
                    list_chars += len(t)
                if t.lstrip().startswith("Error"):
                    errors += 1
    return {
        "case": meta["case"],
        "ok": meta.get("check"),
        "calls": len(calls),
        "prompt": prompt,
        "completion": completion,
        "wall": meta.get("elapsed") or 0,
        "median_latency": statistics.median(latencies) if latencies else 0,
        "list_calls": list_calls,
        "list_chars": list_chars,
        "errors": errors,
    }


def k(n):
    return f"{n/1000:.1f}k" if n >= 1000 else str(n)


def main():
    runs = [Path(p) for p in sys.argv[1:]]
    for run in runs:
        rows = [case_stats(c) for c in sorted(run.iterdir()) if (c / "meta.json").exists()]
        print(f"\n## {run.name}")
        print("| case | ok | calls | prompt | completion | wall | call latency | list-tools | list chars | tool errors |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        tot = {"ok": 0, "calls": 0, "prompt": 0, "completion": 0, "wall": 0.0, "list_calls": 0, "list_chars": 0, "errors": 0}
        lat = []
        for r in rows:
            print(f"| {r['case']} | {'✅' if r['ok'] else '❌'} | {r['calls']} | {k(r['prompt'])} | {r['completion']} | "
                  f"{r['wall']:.1f}s | {r['median_latency']:.2f}s | {r['list_calls']} | {k(r['list_chars'])} | {r['errors']} |")
            for key in tot:
                if key == "ok":
                    tot[key] += 1 if r["ok"] else 0
                else:
                    tot[key] += r[key]
            lat.append(r["median_latency"])
        print(f"| **total** | {tot['ok']}/{len(rows)} | {tot['calls']} | {k(tot['prompt'])} | {tot['completion']} | "
              f"{tot['wall']:.0f}s | {statistics.median(lat) if lat else 0:.2f}s | {tot['list_calls']} | {k(tot['list_chars'])} | {tot['errors']} |")


if __name__ == "__main__":
    main()
