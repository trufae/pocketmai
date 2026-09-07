# Agents and subagents

How MaiCore runs work in child agents, why it does, and what the API looks like
from the outside. This is the design reference; `MaiCore/README.md` covers the
configuration file and `PLUGIN_API.md` covers tools.

## The problem

A chat with tools grows fast. Every call the model makes appends a tool-call
message and a tool-result message to the *main* transcript, and every following
turn re-sends all of it. Reading six files to answer one question can cost more
context than the answer is worth, and the noise stays in the window for the rest
of the conversation.

The context is also undifferentiated. A model deciding "which file holds the
parser?" needs the file listing; the model writing the final answer does not.
Both see everything.

Subagents fix both. A child runs the noisy part in its own transcript, returns
one answer, and disappears. The parent's transcript grows by a single tool
result instead of a dozen messages, and the parent never sees the intermediate
mess.

## Two vocabularies, deliberately kept apart

**An agent definition is a program. An agent process is a running instance.**

| | Definition | Process |
|---|---|---|
| Type | `AgentDefinition` | `AgentProcessInfo` |
| Identity | a string id (`researcher`) | a **pid** (`#4`) |
| Lives in | `pmai.json` under `agents` | the `AgentSupervisor`, for one session |
| Carries | description, provider, model, prompt, tools, limits | state, parent, transcript, usage, attention |
| Listed by | `/agents list` | `/agents tree` |

A definition is also the unit people switch between: rather than changing
provider, then model, then system prompt, then the tool set one command at a
time, `/agent use researcher` swaps all of them at once. That makes a definition
a **preset**, and two fields exist for that role:

- **`description`** — one line saying what the setup is for. People read it when
  picking; a delegating model reads the same line to choose an agent for a task,
  so it is written as a capability ("reads code and finds definitions"), not as
  a label ("Researcher v2").
- **`enabled`** — a parked setup stays in the file and stays listed, but is
  hidden from pickers and never offered as a subagent. Deleting a setup you
  might want next week is worse than hiding it.

Both are edited from every host: `/agents describe ID TEXT` and
`/agents enable|disable ID` in the REPL, the Agents tab in visual mode, and the
same `MaiConfiguration` file the iOS app reads.

The process analogy is not decoration. `agent_start` is fork+exec, `agent_stop`
is kill, `/agents tree` is pstree, and a pid is short enough to type. One
definition can back many concurrent processes; a process always names the
definition it was started from.

## Hosts without the runtime

The family is not tied to `AgentRuntime`. `AgentProcessTools` holds the four
schemas, the parsing of an `agent_start` call, the registration and
bookkeeping of a child in the `AgentSupervisor`, and the answers to
`agent_status`, `agent_result`, and `agent_stop`; the runtime is one caller of
it. A host with a tool loop of its own brings the one thing MaiCore cannot
know — how a child actually runs — as a closure that returns an `AgentResult`,
and gets the same pids, the same queueing, and the same result wording.

PocketMai is such a host. An agent profile whose "Can spawn subagents" switch
is on sees the tools; `agent_start` without a name runs a worker with the
caller's own model and tools, and with a name runs any other profile, whose
description is what the model reads to choose it. A child is an isolated run
of the app's tool loop in a Swift task — no process, no pipe, no ACP — that
reports each turn and tool to the supervisor, holds at its next turn while
paused, and reads the messages queued for it before its next model turn. The
chat shows its children in a bar above the composer, where they can be paused,
messaged, and stopped, and their transcripts read. A chat is one process for
its whole life, registered the first time an agent tool asks for it, reopened
for every turn, and completed between them, so a background child started
three turns ago is still the chat's to collect.

## The tree

Any agent that is allowed subagents can start them, including a subagent. That
makes a tree, not a two-level parent/child split:

```
#1  main            running      3 turns · 1.2k tok
├── #2  researcher  completed    2 turns · 0.4k tok
└── #3  coder       running      5 turns · 2.1k tok
    ├── #4  worker  completed    1 turn  · 0.2k tok
    └── #5  worker  approval?    waiting on write_file
```

Depth is bounded by `limits.maxSubagentDepth`; the turn, token, and time
budgets are shared across the whole tree through a single `RunBudget`, so a
runaway grandchild cannot outspend its grandparent's budget. Concurrency is
bounded by `limits.maxSubagents` per parent agent, and a child started past it
is **queued** rather than refused: the supervisor registers it in the `queued`
state and admits it, oldest first, when a sibling ends. A queued child holds no
slot and no budget; `agent_start` with `wait` false answers `Queued … as #N`
with status `queued`, a blocking start just waits, and `agent_stop` on a queued
child ends the wait like any other cancellation.

## Limits pause, they do not fail

A run that reaches `limits.maxModelTurns`, `limits.maxTotalTokens`, or
`limits.maxSeconds` stops at its next turn boundary — after the tool results of
the last reply, never between a call and its answer — and returns an
`AgentResult` whose `interruption` says which limit it was and whose transcript
is whole. Running that transcript again, on the same pid, picks the task up with
a fresh budget; pmai does this with `/continue`, and by itself when `yolo` is on
and the limit was the turn budget (a checkpoint), never for the token and time
caps a person set to bound the spend. The deadline also cuts a model call
short, and a tool call that would start past it is answered with an error
instead of run. A child that pauses reports to its parent as an error carrying
its last message, and shows as `stopped` in the tree. Failed model calls are
repeated under the agent's `retry` policy first, each announced with
`AgentEvent.retrying`.

## Autocompact

An agent with `autocompact.tokens` above zero has its conversation summarized
by the runtime, before a model turn, once it is estimated to hold that many
tokens — the provider's own input count from the last call when it reports
one, the character count otherwise. Everything except the system prompt and
the newest exchange is folded into one summary message through the same
`prompts.compact` template `/chat compact` uses, with a built-in focus on
finishing the task in hand; the outcome arrives as `transcriptEdited`, or
`compactionFailed` when the model produced nothing, in which case the run
carries on unchanged. The threshold is absolute because context windows differ
per model and few providers say how big theirs is.

**Scoping rule:** a process may only address pids inside its own subtree. `#3`
can stop `#5`; it cannot stop `#1` or inspect `#2`. This is enforced in the
supervisor, not in the prompt.

## The three-part brief

The parent — not the framework — decides what a child needs to know. That is the
whole token argument: the parent has the conversation, so only the parent can
say which 200 words of it matter. `agent_start` therefore takes three separate
fields rather than one blob:

1. **`context`** — what the child must know that it cannot discover. Facts
   already established, decisions already made, paths already found.
2. **`task`** — the single thing to do. One task per process.
3. **`output`** — what to return, and in what shape. "A list of file paths, one
   per line, no prose." The parent is the consumer, so the parent writes the
   contract.

Splitting them beats one free-form prompt for two reasons. The model fills three
labelled slots more reliably than it writes a well-structured brief, and the
host can render them through a template it controls.

That template is the **delegation prompt**: a built-in default in MaiCore,
overridable per installation under `prompts.delegation` in the configuration and
editable with `/edit delegation`. Placeholders: `{{context}}`, `{{task}}`,
`{{output}}`, `{{agent}}`, `{{cwd}}`. Rendering happens in MaiCore, so pmai,
PocketMai, and any other host produce identical child prompts.

The child's transcript is exactly two messages: its definition's instructions as
system, and the rendered brief as user. Nothing from the parent leaks in
implicitly.

## Delegation mode: where tools actually run

`AgentDefinition.toolDelegation` decides whether an agent runs tools itself.

- **`inline`** (default, and what MaiCore has always done) — the agent sees its
  configured tools and calls them in its own transcript.
- **`subagent`** — the agent keeps its concrete tools and is offered the
  `agent_*` family as well when its `agents` tool group is enabled. It can run a
  small call itself and send bulky work one level down, to a child that is
  discarded afterwards. Which tools an agent has is always its definition's
  list, whatever its depth in the tree.

Autocompact starts at 64k tokens by default. Changing it changes how the main agent thinks
about its work, costs an extra model round-trip per delegated task, and is worth
it only when tool output is bulky. It is set per agent with `/set delegation`,
persisted into the agent's definition, and readable and writable from the iOS
app through the same `MaiConfiguration` file.

### The derived worker

`subagent` mode with no configured subagents would give an agent nothing to
delegate to. So when the parent does not name a child definition, MaiCore
derives one: **`<parent>.worker`**, same provider and model, inheriting the
parent's tool allow-list, always `inline` so it does not delegate further, and
taking its instructions from the delegation prompt.

This is what makes the feature usable without configuration: switch delegation
on and the existing agent keeps working, with the option of moving bulky tool
traffic one level down.

Naming a real definition instead (`agent: "researcher"`) is how you get a
*different* model or a *narrower* tool set for the child — a cheap local model
for grep-shaped work, an expensive one for the synthesis.

## Choosing the agent

Same idea as choosing a tool: the caller may pick, or the model may pick.

The `agent` parameter of `agent_start` is a JSON Schema `enum` built from the
caller's `subagentNames`, with each definition's `displayName` in the
description. So the model selects an agent the same way it selects a tool, from
a list it can see, and an unknown name is rejected before anything starts.
Omitting the parameter falls back to the derived worker.

## The tool family

All four are native, reserved names in the `agents` tool group. They are only
offered when that group is enabled for the running agent and its
`limits.maxSubagents` is greater than zero. `/tools enable agents` and `/tools
disable agents` change that permission on the current agent; `/agent tools ID
+agents` and `-agents` change another saved agent.

| Tool | Arguments | Returns |
|---|---|---|
| `agent_start` | `agent?`, `context`, `task`, `output`, `wait?`, `tools?` | pid, plus the answer when `wait` |
| `agent_status` | `pid?`, `tree?`, `log?` | one process, or the caller's subtree; with `pid` and `log`, that agent's recent transcript |
| `agent_result` | `pid`, `wait?` | final answer, usage, stop reason; a child that stopped without answering returns the end of its transcript |
| `agent_stop` | `pid`, `reason?` | what was stopped |

`wait` defaults to **true**: the parent blocks until the child answers. That is
the common case and the one the user asked for — the parent delegates, waits,
and continues with one clean result. `wait: false` returns a pid immediately for
fan-out, and the parent collects with `agent_result` later.

`agent_stop` kills a subtree, not just one node, because a half-stopped tree
leaks running work nobody is waiting for.

`spawn_agent` and `agent_launch` remain as aliases for the blocking and
background forms, so existing configurations keep working.

## States and attention

```
starting → running → completed
   ↑          │  ╲
 queued       │   ╲→ failed
              │    ╲→ cancelled
              │     ╲→ interrupted (a limit paused it; the transcript is whole)
              ↓
    waitingForApproval · waitingForInput · blocked(reason) · paused
```

A background process that needs a human is invisible unless something says so.
The supervisor keeps one **attention** slot per pid:

- `.approval(tool, call)` — a tool call is waiting for a yes or no
- `.input(prompt)` — the process asked its user something
- `.error(message)` — a network failure or interruption stopped progress
- `.finished(summary)` — a background result nobody has collected yet

Approvals set the slot *before* the approval handler is consulted and clear it
after, so a process blocked on a synchronous prompt still shows as
`approval?` in `/agents tree`.

Hosts observe `AgentSupervisor.events`, an `AsyncStream<AgentSupervisorEvent>`.
pmai prints a line when a background process raises attention; PocketMai can
badge it. Neither polls.

## Steering a running process

Waiting for a turn to end before saying "not that file, the other one" wastes
the turn. Every process therefore has an **inbox**: `AgentSupervisor.post(_:to:)`
queues a user message for a pid, and the run reads its inbox at the top of
every model turn — after the tool results the model is about to see — appending
each message to the transcript and emitting `AgentEvent.userMessage`. A message
that lands while the model is producing its final answer does not get lost:
the loop goes round once more so the answer reflects it, unless the turn
budget is spent, in which case the message stays queued for the host.

A chat's own process is registered before its first turn with
`AgentRuntime.allocateProcess(agentID:)`, so messages can wait for a chat that
is idle too; pmai folds them into the next turn it starts. Queued messages are
editable until they are read: `discardLastQueuedMessage`, `discardQueuedMessage(id:)`,
and `clearQueuedMessages` back `/queue pop` and `/queue drop`, and
`AgentProcessInfo.queuedMessages` shows the count in a listing.

Children report through the same event handler as their parent, background or
not, with their own pid in the context. pmai turns that into blocks prefixed
`agent#N` — a child's text is held until a tool call, the next turn, or the end
of its run, then printed whole, so two children never interleave mid-line —
and `ui.subagents` chooses `all`, `tools`, `stats`, or `none`. The ACP server
forwards only depth-0 events to the editor.

## Commands

```
/agents                       definitions, and the live process tree
/agents list                  definitions only
/agents tree                  just the tree; `tok` adds up every model call's input and output,
                              as a provider bills them, and `~` marks counts estimated from text
                              length because the provider reported none
/agents use ID                switch this chat to a setup
/agents describe ID TEXT      set the purpose a model reads when picking
/agents enable|disable ID      park a setup without deleting it
/agent add NAME MODEL GROUPS PROMPT   save a setup in one line (see doc/prompts.md)
/agent tools|model|prompt|provider ID VALUE   change one saved setup
/agent remove ID              drop a setup; subagent lists and the default follow
/edit agent [ID]              edit a setup as JSON in $EDITOR
/agents log PID               that process's transcript
/agents stop PID              pause a process and everything under it at their next step
/agents continue PID          let a paused process go on; queued messages reach it then
/agents kill PID [REASON]     end a process and everything under it
/agents clear                 forget finished processes; the tree keeps only running ones
/agents focus PID|main        send what you type to one process, or back to the chat
@PID TEXT                     one message to one process, focus unchanged
/queue                        what is waiting for each process's next turn
/queue push [@PID] TEXT       queue without sending
/queue pop [PID]              drop the newest queued message
/queue drop [PID]             drop them all
/set ui.subagents LEVEL       all | tools | stats | none
/tools enable|disable agents  allow or deny this agent the agent_* tool family
/set delegation off|subagent      whether this agent may hand tool work to a child
/set limits.maxSubagents N        concurrent children (0 disables the family); more are queued
/set limits.maxSubagentDepth N    how deep the tree may go
/set limits.maxSeconds 10m        wall-clock cap on a run, children included (off to lift)
/set limits.maxTotalTokens 120k   token cap on a run (off to lift)
/set retry.attempts N             repeats of a failed model call; /set retry.delay 5
/set autocompact 120k             summarize older exchanges once the chat holds ~N tokens
/set use.agentsmd on              add the tree's AGENTS.md files (here up to the repo root) to every run's prompt
/continue                         run a paused, failed, or cancelled task on from where it stopped
/edit delegation                  edit the brief template
/edit worker                      edit the derived worker's instructions
/prompts                          lists both alongside compact and system prompts
```

Turning delegation on with no subagent budget would silently do nothing, so
`/set delegation subagent` raises `limits.maxSubagents` to 1 and says it did.

Visual mode carries the same three surfaces: the Agents tab lists setups with
their description and an Enable/Disable button, the focused chat has a "May
delegate tool work" toggle, and a Running agents pane draws the live tree with
a Stop button per row.

## Cost model

What delegation actually buys, for a task that reads six files:

| | inline | subagent |
|---|---|---|
| Main-transcript growth | 6 calls + 6 results (~4k tok) | 1 call + 1 result (~200 tok) |
| Model round-trips | 7 | 8 (one extra for the brief) |
| Cost of the *next* turn | carries all 4k | carries 200 |

The extra round-trip is paid once; the saved context is paid back on every
subsequent turn of the conversation. Delegation therefore wins on long chats
with bulky tools and loses on short chats with terse ones — which is why it is
a per-agent setting and not a global default.

## PocketMai (iOS) — not built yet

PocketMai does not read `MaiConfiguration`; it has its own `AppSettings` with
`ProviderKind`, `OpenAIEndpoint`, `SystemPrompt`, `BuiltInToolID`, and MCP
selections. So it cannot adopt `AgentDefinition` directly, and the preset idea
has to be expressed in its own vocabulary:

```swift
struct AgentPreset: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var description: String        // what it is for; also what a model reads to pick it
  var isEnabled: Bool            // parked, not deleted
  var provider: ProviderKind
  var endpointID: UUID?          // when provider is .openAI
  var modelID: String?
  var systemPromptID: UUID?
  var enabledTools: Set<BuiltInToolID>
  var enabledMCPServers: Set<UUID>
  var enabledMCPTools: Set<String>
  var toolCallingMode: ToolCallingMode?
  var reasoningLevel: ReasoningLevel?
  var maxToolCallsPerTurn: Int?
  var toolDelegation: AgentToolDelegation   // shared with MaiCore
}
```

The work is: those fields plus `agentPresets` and `selectedAgentPresetID` on
`AppSettings`; an `apply(_:to:)` that writes a preset onto a `Conversation` the
way the individual pickers do today; a settings screen that lists, reorders,
describes, enables, and duplicates presets; and a picker in the chat header so
switching setups is one tap instead of four screens. The description field is
what makes automatic selection possible later, exactly as it does in MaiCore.

This is not implemented. `PocketMai/Models/ChatModels.swift`,
`PocketMai/Stores/AppStore.swift`, and `PocketMai/Stores/PersistenceStore.swift`
— the three files it needs — are being rewritten in the working tree by other
work in progress, and landing a second large change into them would collide.

## What is deliberately not here

- **Processes do not survive a restart.** Pids are session-scoped. Persisting a
  half-finished child means persisting a provider connection, and a resumed
  child would answer a question the parent has forgotten. Within a session a
  chat keeps one pid across all its turns, which is what makes a background
  child started three turns ago still collectable.
- **Children do not share the parent's transcript.** Everything a child knows
  arrived through its brief. This is what keeps the cost model honest.
- **No inter-sibling messaging.** `#2` cannot talk to `#3`. Coordination goes
  through the parent, which is the only process with the whole picture.
