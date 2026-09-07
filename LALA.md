# LALA — making pmai solve prompts faster with fewer tokens

Findings from running 13 sample coding workflows (`tmp/cases`) through pmai on
`gemma4:31b` (Ollama cloud, `env-ollamacloud.sh`) with a logging proxy between
pmai and the endpoint, so every request body, tool schema, tool call and usage
figure of every run is on disk (`tmp/results/<run>/<case>/proxy.jsonl`).
`tmp/README.md` explains the harness; `doc/proxy.md` covers the tool proxy.

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
| tool proxy, after | see `doc/proxy.md` | | | |
| toolDelegation subagent | 13/13 | 86 | 454k | 81s |

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
- [x] **Glued tool names** (`3a1655f`, plus the run-loop lookup in this pass).
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
- [x] **Native `respond` in a text protocol** (this pass). The text prompt
  offers a `respond` pseudo-tool; when a server returns it as a native call it
  was "not available to this agent". It is the final answer now.

## 3. Tool catalog: the 3.7k tokens paid on every call

- [ ] **Remove duplicate tools (negative LOC).** `read_text_file` duplicates
  `files_read` (no workspace check, no offset); `run_system` (`command`) duplicates
  `run_sh` (`script`): the model used both interchangeably (`run_system×8` in one
  json run). Dropping the two saves ~1.1k characters per call and two decisions
  for the model. `MaiStandardTools/StandardTools.swift`, `RunTools.swift`.
- [ ] **Fold interpreters into one run tool.** `run_python` and `run_js` each
  cost ~900 characters of schema and were used once in 300+ calls; a
  `language`/`interpreter` argument on `run_sh` (or just `python3 - <<EOF` in
  the shell, which the model already does) covers them. Negative LOC.
- [ ] **Merge `files_read_document` into `files_read`** by extension
  (`.pdf`, `.docx` → converted text, `.json` → outline on request). One tool,
  one description. Negative LOC.
- [ ] **Question `files_chdir`.** Every path argument already accepts a
  relative or absolute path; a working-directory state the model must track is
  a source of errors, and no task used it. Remove, or keep out of the coding
  default group.
- [ ] **Stop repeating the path convention 15 times.** "File path relative to
  the current directory, or an absolute path inside the workspace" appears in
  every files tool (~1.3k characters per call); the workspace name `'work'`
  appears in every description. Say it once in the system prompt (or once in
  the group), describe parameters as `path` only.
- [ ] **Trim rarely used parameters** from `files_grep` / `files_find`
  (`include_ignored`, `depth`, `case_sensitive`, `limit`): together ~1.5k
  characters. Keep them in the implementation with sensible defaults; expose
  the two or three that change results (`glob`, `regex`).
- [ ] **Budget.** Target for the coding set: ≤ 8k characters of schema
  (~2k tokens), i.e. halve the fixed cost. Every 1k characters removed saves
  ~250 tokens × calls per task × tasks: ~19k tokens per 13-task sweep at the
  current call counts.
- [ ] **`todo` group out of the coding default (negative LOC or config).**
  The baseline run spent 8 turns and 54k tokens (13% of the run) on `todo_add`
  + 7× `todo_done` for one rename task; the xml run 12 turns / 60k. Each
  `todo_done` returns the whole list (~490 characters) that then stays in
  context. If the group stays: `todo_done` should accept several items, return
  one line, and the descriptions should say "only for work of five steps or more".
- [ ] **`toolDelegation: subagent` costs +13% and delegated nothing.** It adds
  four `agent_*` schemas (+1.1k tokens per call) while keeping every concrete
  tool visible, so gemma4 never called `agent_start` in 13 tasks.
  `AgentDelegation.swift` says the mode "hides the concrete tools";
  `AgentRuntime.visibleDefinitions` says delegation "never takes the tools
  away". One of them is wrong. Either implement the hiding (the mode then
  forces delegation and can be measured) or remove the mode and its plumbing
  (negative LOC) and rely on explicit `subagentNames`.

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

- [ ] **Add `context.mode = size | cache` to the agent config** and make the
  benchmark report both prompt tokens and a *prefix-reuse* figure (requests
  whose messages are a strict extension of the previous request's; see
  `analyze.py`, which already computes it). In `cache` mode nothing before the
  last user message may change: no compaction rewrite mid-run, no refresh of
  the project-instructions block during a run, volatile blocks (queued user
  messages, repair notes) only appended. In `size` mode the runtime may prune.
- [ ] **File contents are the dominant conversation cost and never leave.**
  In `01-explain` 2.9k of the 3.6k characters of tool output in the final
  window are file bodies already summarised by the answer. Proposal (the
  user's): once a read has been consumed (the model edited, answered, or read
  the next file), replace the body in the transcript with a reference,
  `<file name="cli.py" lines="1-24" sha="…" />`, that the model can re-open
  with `files_read` if it needs it again. Re-reads after edits are rare
  (1–3 per 13 tasks), so the reference is almost always enough. Implement as a
  transcript edit (`AgentTranscriptEdit.rewrite`) applied by the runtime in
  `size` mode, not as a tool the model must remember to call.
- [ ] **Let the model prune, too, but cheaply.** The context tools exist
  (`AgentContextTools.swift`) and were never called in 900 model calls. They are
  invisible to the model unless the group is enabled; if they stay, one
  `context_forget ids` call should be enough, and the system prompt should say
  when to use it. Otherwise remove them (negative LOC) in favour of the
  automatic rewrite above.
- [ ] **Tool results should carry what the next step needs, no more.**
  `files_patch` returns a unified diff (good: no re-read needed, and the model
  did not re-read after patches). `files_replace_range` returns a diff but the
  model re-read the file after it every time to learn the new line numbers
  (json run `03-add-flag`: 30 reads in a loop). Return the resulting line range
  and a few lines of context, and make the description steer towards
  `files_patch` for edits inside a file.
- [ ] **`run_sh` results**: the `[stderr]` label is fine; the absolute cwd and
  duration in structured content are gone now. Consider capping stdout in the
  transcript at N lines with a "saved to …" tail for long outputs (test runs).
- [ ] **Exploration costs turns.** `01-explain` needed `files_list ×2` +
  `files_read ×4` = 6 turns (25k tokens) for four tiny files. Options: a
  recursive `files_list` (tree with sizes, depth-limited), `files_read` taking
  several paths or a glob (the glob support commit exists: say so in the
  description or the model will not use it), and a system prompt that says
  "grep first, read ranges, read one file at a time only when needed".
- [ ] **Measure prefix stability after the sorted-keys fix**, then fix the
  remaining sources: autocompact rewrites, `insertSystem` blocks refreshed per
  prompt (project instructions), the memory block, and the text-protocol
  prompt's position (it is inserted as a second system message after the
  instructions; keep it there and never vary it during a run).

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
