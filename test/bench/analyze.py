#!/usr/bin/env python3
"""Summarize one or more benchmark runs recorded by run.py.

Usage:
  python3 test/bench/analyze.py test/results/<run-id> [more runs...] [--detail CASE]

Prints, per case: model calls, prompt tokens (sum and peak), completion tokens,
tool calls by name, repeated identical calls, tool errors, bytes of tool output
that stayed in the context, share of the final context made of file contents,
wall time and whether check.sh passed. With --detail the per-call timeline of a
case is printed.
"""
import json
import sys
from collections import Counter
from pathlib import Path


def text_of(content):
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    return "".join(p.get("text", "") for p in content if isinstance(p, dict))


def load_calls(path):
    calls = []
    for line in open(path):
        try:
            calls.append(json.loads(line))
        except Exception:
            pass
    return calls


def est_tokens(chars):
    return chars // 4


def analyze_case(case_dir):
    meta = json.loads((case_dir / "meta.json").read_text())
    log = case_dir / "proxy.jsonl"
    calls = load_calls(log) if log.exists() else []
    prompt_tokens = []
    completion_tokens = 0
    reasoning_chars = 0
    tool_calls = []
    errors = 0
    tools_json_chars = 0
    system_chars = 0
    final_msgs = []
    for call in calls:
        req = call.get("request") or {}
        res = call.get("response") or {}
        usage = res.get("usage") or {}
        prompt_tokens.append(usage.get("prompt_tokens", 0))
        completion_tokens += usage.get("completion_tokens", 0)
        reasoning_chars += len(res.get("reasoning") or "")
        if call.get("error") or call.get("status", 200) >= 400:
            errors += 1
        for tc in res.get("tool_calls") or []:
            tool_calls.append((tc.get("name"), tc.get("arguments", "")))
        if req.get("tools"):
            tools_json_chars = len(json.dumps(req["tools"]))
        msgs = req.get("messages") or []
        if msgs:
            final_msgs = msgs
            for m in msgs:
                if m.get("role") == "system":
                    system_chars = len(text_of(m.get("content")))
    # Context composition of the last request: what is sitting in the window.
    tool_result_chars = 0
    file_chars = 0
    structured_chars = 0
    tool_errors = 0
    per_tool_result = Counter()
    id_to_name = {}
    for m in final_msgs:
        if m.get("role") == "assistant":
            for tc in m.get("tool_calls") or []:
                id_to_name[tc.get("id")] = (tc.get("function") or {}).get("name")
    for m in final_msgs:
        if m.get("role") == "tool":
            text = text_of(m.get("content"))
            tool_result_chars += len(text)
            name = id_to_name.get(m.get("tool_call_id"), "?")
            per_tool_result[name] += len(text)
            if "<file " in text or "<file>" in text:
                file_chars += len(text)
            if "<structured_content>" in text:
                start = text.index("<structured_content>")
                end = text.find("</structured_content>", start)
                structured_chars += (end if end > 0 else len(text)) - start
            if text.lstrip().lower().startswith(("error", "tool error")) or '"isError":true' in text:
                tool_errors += 1
    names = Counter(n for n, _ in tool_calls)
    repeats = sum(c - 1 for c in Counter(tool_calls).values() if c > 1)
    # KV-cache view: how many requests changed something before the messages
    # the previous request already carried (0 means every call only appended).
    prefix_changed = 0
    prev = None
    for call in calls:
        msgs = (call.get("request") or {}).get("messages") or []
        if prev is not None and msgs[:len(prev)] != prev:
            prefix_changed += 1
        prev = msgs
    return {
        "prefix_changed": prefix_changed,
        "case": meta["case"],
        "pass": meta.get("check"),
        "calls": len(calls),
        "prompt_sum": sum(prompt_tokens),
        "prompt_peak": max(prompt_tokens) if prompt_tokens else 0,
        "prompt_first": prompt_tokens[0] if prompt_tokens else 0,
        "completion": completion_tokens,
        "reasoning_chars": reasoning_chars,
        "tool_calls": len(tool_calls),
        "tool_names": names,
        "repeats": repeats,
        "tool_errors": tool_errors,
        "http_errors": errors,
        "tool_result_chars": tool_result_chars,
        "file_chars": file_chars,
        "structured_chars": structured_chars,
        "per_tool_result": per_tool_result,
        "tools_json_chars": tools_json_chars,
        "system_chars": system_chars,
        "elapsed": meta.get("elapsed"),
        "timed_out": meta.get("timed_out"),
        "changed": meta.get("changed_files", []),
        "check_output": meta.get("check_output", ""),
    }


def fmt_k(n):
    return f"{n/1000:.1f}k" if n >= 1000 else str(n)


def print_summary(run_dir, rows):
    print(f"\n## {run_dir.name}")
    print()
    print("| case | ok | calls | tool calls | prompt Σ | peak | compl | repeat | tool err | ctx tool-out | file part | prefix Δ | time |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    tot = Counter()
    for r in rows:
        ok = "✅" if r["pass"] else ("❌" if r["pass"] is False else "–")
        if r["timed_out"]:
            ok += "⏱"
        print(f"| {r['case']} | {ok} | {r['calls']} | {r['tool_calls']} | {fmt_k(r['prompt_sum'])} | {fmt_k(r['prompt_peak'])} | "
              f"{r['completion']} | {r['repeats']} | {r['tool_errors']} | {fmt_k(r['tool_result_chars'])} | "
              f"{fmt_k(r['file_chars'])} | {r['prefix_changed']} | {r['elapsed']}s |")
        for key in ("calls", "tool_calls", "prompt_sum", "completion", "repeats", "tool_errors", "prefix_changed"):
            tot[key] += r[key]
        tot["pass"] += 1 if r["pass"] else 0
        tot["elapsed"] += r["elapsed"] or 0
    print(f"| **total** | {tot['pass']}/{len(rows)} | {tot['calls']} | {tot['tool_calls']} | {fmt_k(tot['prompt_sum'])} | | "
          f"{tot['completion']} | {tot['repeats']} | {tot['tool_errors']} | | | {tot['prefix_changed']} | {tot['elapsed']:.0f}s |")
    names = Counter()
    for r in rows:
        names.update(r["tool_names"])
    print()
    print("Tool usage:", ", ".join(f"{n}×{c}" for n, c in names.most_common()))
    if rows:
        print(f"Tool schema JSON: {rows[0]['tools_json_chars']} chars (~{est_tokens(rows[0]['tools_json_chars'])} tokens); "
              f"system prompt: {rows[0]['system_chars']} chars; first-call prompt tokens: {rows[0]['prompt_first']}")


def print_detail(case_dir):
    calls = load_calls(case_dir / "proxy.jsonl")
    meta = json.loads((case_dir / "meta.json").read_text())
    print(f"\n### {meta['case']} — {meta['variant']} {meta['model']} — check={meta.get('check')} elapsed={meta.get('elapsed')}s")
    print(f"prompt: {meta['prompt']}")
    for call in calls:
        res = call.get("response") or {}
        usage = res.get("usage") or {}
        req = call.get("request") or {}
        # the tool results this call saw for the first time = tool msgs after the last assistant msg
        msgs = req.get("messages") or []
        new_tool_chars = 0
        for m in reversed(msgs):
            if m.get("role") == "tool":
                new_tool_chars += len(text_of(m.get("content")))
            else:
                break
        tcs = ", ".join(f"{tc.get('name')}({tc.get('arguments','')[:90]})" for tc in res.get("tool_calls") or [])
        content = (res.get("content") or "").strip().replace("\n", " ")
        reasoning = len(res.get("reasoning") or "")
        line = (f"#{call.get('seq'):2d} {call.get('elapsed'):5.1f}s in={usage.get('prompt_tokens')} out={usage.get('completion_tokens')}"
                f" new_tool_out={new_tool_chars}c")
        if reasoning:
            line += f" reasoning={reasoning}c"
        if tcs:
            line += f" → {tcs}"
        if content:
            line += f" | {content[:140]}"
        if call.get("error"):
            line += f" ERROR {str(call['error'])[:200]}"
        print(line)
    if meta.get("check_output"):
        print("check:", meta["check_output"][:500])


def main():
    args = sys.argv[1:]
    detail = None
    if "--detail" in args:
        i = args.index("--detail")
        detail = args[i + 1]
        del args[i:i + 2]
    for run in args:
        run_dir = Path(run)
        cases = sorted(p for p in run_dir.iterdir() if (p / "meta.json").exists())
        if detail:
            for c in cases:
                if c.name == detail or detail == "all":
                    print_detail(c)
            continue
        rows = [analyze_case(c) for c in cases]
        print_summary(run_dir, rows)


if __name__ == "__main__":
    main()
