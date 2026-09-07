# LALA — making pmai solve prompts faster with fewer tokens

Findings from running 13 sample coding workflows (`test/cases`) through pmai on
`gemma4:31b` (Ollama cloud, `env-ollamacloud.sh`) with a logging proxy between
pmai and the endpoint, so every request body, tool schema, tool call and usage
figure of every run is on disk (`test/results/<run>/<case>/proxy.jsonl`).
`test/README.md` explains the harness; `doc/proxy.md` covers the tool proxy.

Each item is a todo. Ticked items were fixed in this pass, one commit each, so
the commit log (`git log b75177e..`) can be reviewed alongside this file.
Unticked items are proposals with the measurement that motivates them. Where a
proposal removes code, that is said explicitly: the preferred outcome for
MaiCore is fewer lines, not more.

## 1. Where the tokens go

Single runs, 13 tasks each, native tool calling unless noted. Numbers are the
sum over the 13 tasks; a single run is noisy (the same task took 18 model calls
once and 7 the next time because the model chose to bookkeep with `todo_*`).

| configuration | solved | model calls | prompt tokens | wall |
|---|---|---|---|---|
| native tools, before fixes | 11/13 | 84 | 402k | 85s |
| native tools, after fixes (two runs) | 13/13, 12/13 | 76, 83 | 334k, 386k | 86s, 103s |
| text protocol, before | 0/13 (40 turns each) | ~40/task | ~200k/task | ~30s/task |
| text protocol, after | 13/13 | 115 | 454k | 141s |
| xml protocol, after | 12/13 | 91 | 352k | 93s |
| json protocol, after (two runs) | 12/13, 12/13 | 132, 97 | 582k, 341k | 130s, 110s |
| tool proxy, before | 4/13 (5 refusals) | 49 | 107k | 91s |
| tool proxy, after | 8/13 | 128 | 167k | 168s |
| toolDelegation subagent | 13/13 | 86 | 454k | 81s |
| **after the catalog cut (section 3)** | | | | |
| native tools | 12/13 | 89 | 242k | 81s |
| text protocol | 11/13 | 101 | 234k | 97s |
| toolDelegation subagent | 12/13 | 94 | 311k | 84s |

The catalog cut took the fixed cost per call from 23 tools / 16.1k characters
(3,756 prompt tokens on the first call) to 17 tools / 8.9k characters (2,153),
and the text-protocol prompt from 12.8k to 7.2k characters. The remaining
failures after the cut are the `13-big-log` shell mistake the model makes every
time, the `10-readme` respond dump in the text protocol (section 4), and, in
the first sweep only, `07-find-usage`: the benchmark's work directory is
git-ignored and `files_grep` searched nothing, which `fb248bf` fixes; the case
passes again in 2 calls.

Three facts decide everything below:

- **The fixed cost per call is 74–85% of all prompt tokens.** The 23 standard
  tool schemas are 16k characters (~3.7k tokens) and are resent on every call.
  Across the baseline run that is ~316k of 402k tokens. The conversation itself
  (user prompt, tool calls, tool results, answers) is the remaining ~86k.
- **Wall time is round trips.** Model time equals wall time within 3%; tools
  are instant on these tasks. Each call costs 0.5–1.2s on the cloud endpoint,
  so a 7-call task takes 6s and a 40-call loop 30–100s. Fewer turns is the
  only way to be faster.
- **Output is tiny.** 5–8k completion tokens per 13 tasks. Nothing to gain
  there; everything is on the input side.

## 2. Bugs fixed in this pass (one commit each)

- [x] **Text/xml/json protocols never finished a task** (`b75177e`). Ollama
  parses gemma's own function-call syntax into native `tool_calls` even when
  the request offers no tools. The loop read only the text, saw no call,
  appended `missing_tool_call` feedback and asked again, until `maxModelTurns`.
  Every task: 40 calls, ~160–200k tokens, nothing done. Native calls in a text
  protocol now run like any native turn. After: text 13/13, xml 12/13, json 12/13.
- [x] **Every tool result was sent twice** (`87cef61`, `6b81c1b`). Each result
  carried a `<structured_content>` JSON copy of its text: a `files_list` result
  was more than doubled, `files_read` appended offsets, `run_sh` appended the
  absolute cwd and a duration, on every later request of the run. Structured
  content now goes out only when a result has no text (MCP tools that answer
  with structured data alone).
- [x] **Prompt prefix changed on almost every request** (`ba09ecf`).
  `JSONValue.compactJSONString` used an unsorted encoder, so the same message
  rendered differently each time: 57 of 71 consecutive requests in the baseline
  run differed from the previous one somewhere in the middle. Any server-side
  prompt cache (llama.cpp, vLLM, Ollama) misses from that message on. Sorted keys.
- [x] **Tool proxy refused work** (`749db0d`). With only `list-tools` and
  `call-tool` visible, 5 of 13 tasks ended with "I do not have access to your
  file system". The proxy definitions now list the enabled tool names (~120
  tokens); `list-tools` ranks name matches first and describes at most six
  tools in full (a broad search returned 10.9k characters before).
- [x] **Tool proxy nested envelope** (`381901c`). gemma sends
  `{"name":T,"arguments":{"name":T,"arguments":{…}}}`; the inner envelope
  reached the tool, `path` was "missing", the identical call repeated 40 times.
- [x] **Glued tool names** (`3a1655f`, run-loop lookup `64f5ece`).
  Servers hand over names like `run_sh Optimize:` or `files_read:`. The
  resolver now tries the leading identifier, and the run loop uses the resolver
  too (text protocols offer no tools, so the provider's resolver is empty).
- [x] **Empty reply killed the run** (`55fb63c`). A swallowed malformed call
  returns empty content; the provider threw, the loop retried twice with 5s
  pauses and failed the whole task. Three tasks died this way. Mid tool loop an
  empty reply is now repair feedback, not a retry.
- [x] **The identical-call guard did not end anything** (`564e280`). It
  refused the 4th identical call with an error, then the model repeated it 36
  more times (~150k tokens). Once the guard trips, the next turn gets no tools
  and a note to answer with what it has.
- [x] **Empty replies in a row were also endless** (`dd85f41`). Same treatment
  after three consecutive empty replies; the error also carries its message again.
- [x] **Native `respond` in a text protocol** (`c36ca7b`). The text prompt
  offers a `respond` pseudo-tool; when a server returns it as a native call it
  was "not available to this agent". It is the final answer now.
- [x] **Tool proxy made hybrid** (`9ffb9e3`, `e2a74f3`). The pure proxy
  solved 5–8 of 13 tasks: the model called hidden tools by name (swallowed by
  the server), escaped file bodies twice, and wrapped calls in every envelope
  shape. The six common tools stay native, the rest sit behind `list-tools`
  whose description is generated from them; 12/13 at two thirds of the native
  tokens. `doc/proxy.md` has the study.
- [x] **Tool output noise** (`8f4f777`). The call line showed raw JSON (a
  `files_write` printed the whole escaped file) and the result hid under a
  heading. Calls are one readable line (`→ files_read cli.py`,
  `→ files_patch path=… find=… (+1 lines) replace=…`), results start right
  after `←`, errors read `← Error: …`; the same renderers serve child-agent
  blocks and the visual mode. Still open: `ui.toolResultLines` defaults to all
  lines, so a 500-line read floods the terminal; a default of ~40 with the
  `… N more lines` tail is probably right, and `ui.subagents` could gain a
  `results` level (results only, no calls) to match what people read.

## 3. Tool catalog: the 3.7k tokens paid on every call

Done in this pass, one commit each; the schema set went from 23 tools and
16,098 characters to 17 tools and 8,940 characters (−44%), the text-protocol
prompt from 12,812 to 7,163 characters, and MaiStandardTools lost more lines
than it gained.

- [x] **Duplicate tools removed** (`818b499`, `613f4cf`). `read_text_file`
  duplicated `files_read`; `run_system` duplicated `run_sh`. Gone, with their
  schemas (~1.1k characters per call).
- [x] **One run tool** (`613f4cf`). `run_python` and `run_js` (used once in 300
  calls) are folded into `run_sh`; other languages go through the shell
  (`python3 - <<'EOF' … EOF`). The `runPython`/`runNode` options went with them.
- [x] **`files_read_document` merged into `files_read`** (`8b68ed5`): `.pdf`
  and `.docx` are converted to Markdown, everything else, JSON included, stays
  the raw text a model can patch. The iOS host lost only the removed name.
- [x] **`files_chdir` removed** (`ffd1fa8`). Every path argument takes a
  relative or absolute path; `/cd` stays for the person at the prompt.
- [x] **Path convention said once** (`67413d5`). `files_list` states it; every
  other path argument is "File path." and each tool has a one-sentence
  description without the workspace name (~1.3k characters per call).
- [x] **Rare search arguments dropped** (`67413d5`). `files_find` lost `depth`,
  `include_ignored`, `limit`; `files_grep` lost those and `case_sensitive`,
  with the implementation that served them. Defaults: smart case, 100 matches,
  source paths only. Follow-up (`fb248bf`): a folder the repository ignores
  now falls back to the filesystem walk instead of "No matching lines."
- [x] **Budget met.** Target was ≤ 8k characters for the coding set; the
  `files` + `run` groups are 7.9k, `todo` adds 1.0k. First-call prompt tokens
  3,756 → 2,153; a 13-task sweep 334–386k → 242k prompt tokens with the same
  model calls.
- [x] **Todo tools slimmed** (`2b8d876`). `todo_done` takes several items per
  call, `todo_add`/`todo_done` answer in one line instead of echoing the list,
  and the descriptions say "work of five or more steps". The group stays in
  the default set; measure whether to drop it from coding agents once the
  system prompt (section 6) exists.
- [x] **Delegation described truthfully, agent_* schemas halved** (`06edcea`).
  `AgentDelegation.swift` claimed the subagent mode hides the concrete tools;
  the runtime and `doc/agents.md` keep them and add `agent_*`, and that is
  what the comment says now, with its cost. The four schemas went from ~3.2k
  to ~2.4k characters. Still open: the mode delegated nothing in 26 tasks;
  section 8 decides whether it earns its place.
- [ ] **Not yet verified on iOS.** `PocketMai/Services/ToolAgent.swift` and
  `FileWorkspaceService.swift` only lost references to the removed name, but
  the app was not built in this pass.

## 4. Text protocols

- [ ] **The text prompt is as heavy as the schemas.** The generated
  `## Available Tools` block is 12.8k characters (~3k tokens) per call, built
  from the same descriptions. Every item in section 3 shrinks it too.
- [ ] **Repair feedback advertises `respond` and models take the hint.** After
  a swallowed `files_write`, the feedback says "You may also call respond with
  final content"; in two runs the model then *answered with the README text*
  instead of writing the file (xml `10-readme`, json `10-readme`). Drop the
  `respond` example from `missingPostToolActionMessage`; consider removing the
  `respond` pseudo-tool entirely (`AgentToolLoopPolicy.responseToolDefinition`
  and its parsing paths): a plain answer is already the final answer. Negative LOC.
- [ ] **Repair feedback is appended as an assistant message.** The model then
  continues after "its own" `<tool_run>missing_tool_call…` block. Measure a
  user-role variant on the same 13 tasks; keep whichever needs fewer repairs.
- [ ] **Text protocols do not stream** (`stream: usesTextToolProtocol ? false`).
  Tool calls arrive whole anyway, but the final answer is not streamed either,
  so the user waits the whole generation. Stream and parse the buffered text at
  the end.
- [ ] **The text protocol is textual only on the way in.** The model's
  `TOOL_CALL` block is stored as a native `tool_calls` message and the result
  as a `tool` role message. That is what primes gemma to switch to its native
  function-call syntax on the next turn, which some servers swallow (the empty
  replies above). Option: keep the exchange textual end to end (result as a
  user-role `<tool_run>` block) for servers that do not parse tool calls, and
  measure the empty-reply rate.

## 5. Context debt and KV-cache friendliness

The user's framing: protocol scaffolding is a per-prompt need, not history; and
there are two different optimisation targets that should be selectable and
measured separately, context size (rewrite/prune old messages) versus cache
reuse (append only, never touch old messages).

- [x] **`context: cache | size` on the agent** (`f843dc7`, `8455b59`; `/set
  context`, runner `--context`). `cache`, the default, never changes a sent
  message; `size` prunes as described below. `analyze.py` reports a *prefix Δ*
  column (requests that changed something the previous request already
  carried): 0 in cache mode on every run, 1–4 in size mode, all of them the
  rewrites. Autocompact stays as configured in both modes (it is off by
  default and an explicit choice when on).
- [x] **File bodies collapse to a reference in size mode** (`f843dc7`,
  `8455b59`). `AgentContextPruning` replaces a `files_read` body with
  `[cli.py: 24 lines, 572 characters, read earlier and removed from the
  context; call files_read again if needed]`, as a transcript edit the REPL
  shows as `✂ context`. **Measured, and the first version was wrong:** pruning
  bodies read two results ago *inside the same run* made the model re-read
  them when it wrote the answer (`01-explain`: 10 calls and 27k tokens instead
  of 7 and 18k in one run, neutral in the other; every other task reads too
  few files for it to fire). Two size-mode sweeps totalled 206k and 214k
  prompt tokens against 215k and 206k in cache mode: a wash on single-prompt
  tasks. So the current prompt's reads now stay untouched and only bodies
  read for *earlier* prompts collapse, which is where the debt accumulates in
  a long chat. Open: a multi-prompt benchmark case (the runner is one-shot) to
  measure that saving, and extending the rule to long `run_sh` outputs of
  earlier prompts.
- [x] **Context tools removed** (`150afc7`). Never called in 900+ model calls
  while costing four schemas on every call of the default agent. The edit
  types, the editor and the `transcriptEdited` event stay for the automatic
  pruning above; the tools, their supervisor queue and the runtime drain are
  gone (−400 lines).
- [x] **Tool results carry what the next step needs** (`240c9a5`, `cc2e74a`).
  `files_replace_range` names the resulting line range ("now lines 5-12 of
  19") and its description steers to `files_patch`; `files_grep` says in its
  text when it stopped at 100 matching lines (the structured flag no longer
  reaches the model, and a proxy run had counted the 100 lines as the total).
- [x] **`run_sh` keeps 24 KB per stream instead of 100 KB** (`41df7e2`). The
  truncation note says how much was dropped; head, tail or grep get the rest.
- [x] **Exploration nudges** (`dc3e68e`): `files_list` says it lists one folder
  and points at `files_find` with `*` for the whole tree; `files_find` says so
  too. No new tree tool: `files_find` already does it. Still open: a
  `files_read` that takes several paths (one call instead of four for a small
  package), and the system prompt line "grep first, read ranges" (section 6).
- [x] **Prefix stability measured after the fixes:** 0 of 66 consecutive
  native requests and 0 of 88 text-protocol requests change their prefix (57 of
  71 did before). Within a run nothing before the last message moves:
  autocompact is off by default (`tokens: 0`), the project-instructions and
  memory blocks are set between prompts and fixed for the run, and the
  text-protocol prompt sits in a stable second system message. Add
  `compare.py`'s prefix figure to every sweep (done in `analyze.py`).

## 6. The default prompt

- [ ] **"You are a helpful assistant. Use tools when needed." is the entire
  coding prompt.** Every workflow mistake above is a mistake the prompt did not
  forbid. Write one compact coding prompt (≤ 600 characters) and measure it
  with `run.py --system FILE`: grep before reading, read a range not a file,
  `files_patch` not rewrite, run the tests once at the end, do not re-read what
  a diff already showed, no `todo_*` for fewer than five steps, answer in a few
  lines. Keep it as the `main` default for pmai and PocketMai.
- [ ] **Model errors that a prompt line can catch.** `13-big-log` failed
  twice on the same shell mistake (`cut -d' '` on a message containing spaces
  gave "timeout waiting for upstream (req=998)" as the top error): one line
  "check aggregate results against the raw data before answering" is cheap to
  test.

## 7. Runtime guards and errors

- [ ] **A stuck run still burns the turn budget until the guard trips.**
  Consider a "no progress" rule: N consecutive tool errors of the same kind
  (not only identical calls) withdraws the tools as well.
- [ ] **`files_patch` needs `replace_all`.** Every multi-match rename cost two
  turns ("Expected 1 patch matches, found 4", then `expected_matches`). A
  boolean saves a turn per file.
- [ ] **Unknown argument keys are dropped silently**, then the error says "No
  fields were given" (`Tooling.swift:321`). Name the unknown keys so the model
  can fix the shape in one turn (this is how the nested envelope hid).
- [ ] **`maxModelTurns`/`maxToolCalls` default 50** means a runaway run costs
  ~200k tokens before stopping. With the guards above 20–25 is enough for
  these tasks; make the default smaller or budget by tokens.

## 8. Subagents

- [ ] Measured only the `subagent` delegation mode (section 3). Next: a case
  that *needs* delegation (a repo too large to read in one context; two
  independent sub-tasks), run with explicit `subagentNames` and a worker whose
  tools are the files/run groups, and compare parent tokens and wall time
  against inline. Record `agent_start` briefs and child transcripts
  (`/export debug` carries them) to judge whether the brief template
  (`AgentDelegationPrompt.template`) gives children what they need without
  repeating the parent's context.
- [ ] Decide the delegation semantics (hide or not) before adding anything;
  see the mismatch in section 3.

## 9. Benchmark harness todos

- [ ] Repeat each sweep 3× and report medians; single runs vary by ±15% on
  totals and by 2× on individual tasks.
- [ ] More cases: a multi-file feature, a repo large enough that reading
  everything is impossible (forces grep/ranges), a change that breaks a test
  elsewhere, a long conversation that triggers autocompact, and one that needs
  a subagent.
- [ ] Other models: `gpt-oss:120b`, `qwen3.5:397b`, `kimi-k2.7-code` on the
  cloud; `qwen3-coder:30b` locally (`127.0.0.1:11434`) for the small-model
  view where text protocols matter most.
- [ ] Add a `--prompt-variant` matrix (default vs coding prompt) and a
  `--context-mode` switch once section 5 lands, so both can be compared on the
  same runs.
- [ ] Guard the harness against killed sweeps: launching several `run.py`
  in one shell and exiting killed the proxy runs twice; run them as separate
  jobs or wait on all of them.
