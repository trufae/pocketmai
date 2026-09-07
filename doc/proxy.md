# The tool proxy: what it saves and what it costs

`useToolProxy` on an agent replaces the whole tool catalog offered to the model
with two tools, `list-tools` and `call-tool`. This note explains the mechanism,
the token arithmetic behind it, what the `tmp/` benchmark measured on
`gemma4:31b`, the bugs that measurement found, and when the mode pays off.
`MaiCore/README.md` documents the setting; `doc/agents.md` covers subagents,
the other way MaiCore keeps a transcript small.

## Mechanism

Without the proxy, every request carries the JSON schema of every enabled tool.
The standard coding set (`files`, `run`, `todo`: 23 tools) is about 16k
characters, roughly 3.7k tokens, and it is resent on every model turn of every
run because the schemas live outside the conversation.

With the proxy, the request carries only the two proxy schemas (about 290
tokens). The model calls `list-tools keywords=…` to learn what exists and how
to call it, then `call-tool name=… arguments={…}`. The runtime resolves the
concrete tool (`ToolProxy.resolveCall`) and runs it exactly as if it had been
called directly; approval rules, the identical-call guard and the tool budget
all apply to the resolved call.

The difference is where the description lives. Native schemas are a fixed cost
per call and never enter the transcript. A `list-tools` result is a tool
message: it enters the transcript once and is then resent on every later turn
of the run, like any other message. So the proxy trades a per-call cost for a
one-time cost that becomes context debt.

## Arithmetic

Let `S` be the schema tokens per call, `L` the tokens of the listings the model
asks for, `N` the number of model turns in a run. Native mode pays `S × N`. The
proxy pays roughly `L × (N − k)` where `k` is the turn on which the listing was
requested, plus the extra turns spent on `list-tools` itself.

With `S ≈ 3.7k`, a run of 7 turns pays about 26k tokens for schemas. The proxy
wins as long as the listings it pulls into the transcript stay well below the
schema size and cost few extra turns. It loses when `list-tools` returns most of
the catalog: before the fix below, a search for `read file list files` returned
10.9k characters (about 2.7k tokens), nearly the whole native schema set,
which then stayed in the transcript for the rest of the run.

## What the benchmark measured

Thirteen coding tasks, `gemma4:31b` on Ollama cloud, one run per
configuration. Totals over the 13 tasks (a single run each; expect noise of a
few tasks' worth between repeats):

| configuration | solved | model calls | prompt tokens | first-call prompt |
|---|---|---|---|---|
| native schemas, before fixes | 11/13 | 84 | 402k | 3,756 |
| native schemas, after fixes | 13/13 | 76 | 334k | 3,756 |
| proxy, before fixes | 4/13 | 49 | 107k | 219 |
| proxy, after fixes | 8/13 | 128 | 167k | 344 |

The proxy's low total before the fixes is not a saving: in 5 of the 13 tasks
the model never called a tool. Seeing only `list-tools` and `call-tool` it
answered "I do not have access to your local file system" and stopped. Where
it did work, the saving was real: the rename task cost 24.6k prompt tokens
through the proxy against 108.9k natively, the C build fix 15.7k against 48.7k,
the grep question 3.7k against 7.9k.

### Bugs found and fixed

1. **The proxy tools did not say what they reach.** Their descriptions named no
   capability, so the model declined tasks it could do. The definitions now end
   with the enabled tool names (`Enabled tools: files_find, files_grep, …`),
   about 120 tokens for the standard set. With the names in hand the model often
   skips `list-tools` and calls the tool directly (`749db0d`).
2. **`list-tools` returned everything with all arguments.** Terms found in a
   tool's name now rank above terms found in its text, the first six matches are
   described with their arguments, the rest are named in one line, and the
   result tells the model to search by name for details (`749db0d`).
3. **Nested envelopes.** `gemma4` sends
   `{"name":"files_read","arguments":{"name":"files_read","arguments":{"path":"cli.py"}}}`.
   The inner envelope reached the tool as its arguments, `path` was reported
   missing, and the model repeated the identical call until the turn limit
   (40 calls, 44 seconds, for a task that takes 7 natively). The resolver now
   unwraps an arguments object that holds only envelope keys (`381901c`).
4. **The identical-call guard did not end anything.** It refused the fourth
   identical call with an error but the model kept repeating it, and the run
   burned the remaining 36 turns. Once the guard trips, the next turn is offered
   no tools and asked to answer with what it has (`564e280`). This is a runtime
   fix, not a proxy one, but proxy mode is where it bit first: a model that
   misunderstands the envelope repeats itself exactly.

### After the fixes

After the four fixes the proxy solved 8 of 13 tasks (128 model calls, 167k
prompt tokens, 21k completion tokens, 168s) against 12–13 of 13 for native
schemas at 334–386k prompt tokens. Half the tokens, but a third of the tasks
lost, and the remaining failures are structural rather than bugs:

- **Writing files through nested JSON.** `call-tool` puts the file body inside
  `arguments` inside the outer arguments object; two levels of JSON escaping.
  gemma4's `files_write` calls came back malformed and were swallowed by the
  server (empty replies), or the content arrived empty (`Error: content is
  required.`). The three tasks that create or rewrite a file (`03`, `10`, `11`)
  all failed this way; tasks that only patch, grep or run passed.
- **Three times the completion tokens.** Every call is wrapped in an envelope,
  and the model spells the tool name twice. 21k completion tokens against 6k.
- **A listing is context debt.** Where the model did call `list-tools`, the
  result (now ≤ ~3k characters) stayed in the transcript for the rest of the
  run; natively the schemas cost the same on every call but never accumulate.

The saving is real on read-mostly work (the rename task: 25k tokens through
the proxy against 34–109k natively; the grep question: 3.7k against 7.6k) and
disappears on write-heavy work.

## When to use it

- **Many tools, few needed per task.** MCP servers with dozens of tools, or an
  agent with `github`, `web`, `mastodon` and `files` enabled at once. The
  schema cost grows with the catalog; the proxy's cost grows only with what a
  task actually asks about.
- **Small, stable coding set: probably not.** The 23 standard tools cost about
  3.7k tokens per call. Trimming that catalog (duplicate tools, repeated path
  conventions in every description, the `todo` group for short tasks; see
  `LALA.md`) attacks the same cost without adding a round trip or a listing
  that stays in the transcript. A model that knows its tools also makes fewer
  mistakes than one that must learn them mid-run.
- **Hybrid worth trying.** Offer the six most used tools natively
  (`files_read`, `files_grep`, `files_patch`, `files_write`, `run_sh`,
  `files_list`) and put the rest behind the proxy. That keeps the per-call
  cost near 1k tokens and still reaches everything.

## Measuring it yourself

    python3 tmp/bench/run.py --variant proxy
    python3 tmp/bench/analyze.py tmp/results/<run-id> --detail all

The `--detail` timeline shows each `list-tools` call and how many characters
its result added (`new_tool_out`), which is exactly the context debt discussed
above.
