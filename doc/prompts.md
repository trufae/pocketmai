# Prompts and agent definitions

How system prompts are stored, how agents refer to them, and the one-line
commands that register a prompt, register an agent around it, give it tools,
and change any of that afterwards.

## Named system prompts

Every agent takes its instructions from one **named system prompt**. The
catalog lives under `prompts.system` in the configuration
(`~/.config/pmai/config.json` unless `--config` says otherwise), and each
agent names the prompt it uses:

```json
"prompts": {
  "system": {
    "main": "You are a helpful, concise assistant.",
    "reviewer": "You review diffs and list only real defects."
  }
},
"agents": [
  { "id": "main",     "systemPrompt": "main",     "instructions": "You are a helpful, concise assistant.", "...": "..." },
  { "id": "reviewer", "systemPrompt": "reviewer", "instructions": "You review diffs and list only real defects.", "...": "..." }
]
```

`systemPrompt` is the reference; `instructions` is a copy of that prompt's
text, kept in step whenever the prompt changes, so a run needs no lookup and
readers that only know `instructions` keep working. Several agents may share
one prompt, and editing it changes all of them at once.

Two rules keep the catalog and the agents from disagreeing:

- **Loading**: an agent written without `systemPrompt` — an older file, or a
  hand edit — is given a same-named prompt holding its inline text. Where a
  prompt's text and an agent's copy differ, the prompt wins and the copy is
  refreshed.
- **Saving an agent**: its `instructions` become the text of its named
  prompt, and every other agent sharing that prompt is refreshed. So "edit
  this agent's prompt" and "edit the prompt" are the same operation, whether
  it happens through `/prompt edit`, `/edit agent`, or the iOS app; the
  helpers (`setSystemPrompt`, `assignSystemPrompt`, `upsertAgent`,
  `removeAgent` on `MaiConfiguration`) live in MaiCore so every host applies
  the same rules.

A prompt that no agent uses is fine — it waits in the catalog until an agent
is pointed at it. A prompt that is in use cannot be dropped until its agents
are moved.

## Commands

```
/prompts                     list prompts and which agents use them
/prompt                      show the current agent's prompt
/prompt show NAME            print one prompt
/prompt add NAME TEXT        create a prompt from one line (/prompt set NAME TEXT replaces)
/prompt edit [NAME]          edit or create one in $EDITOR (current agent's when omitted)
/prompt rm NAME              drop an unused prompt
/prompt use NAME             point the current agent at a prompt (/prompt NAME does the same)
/agent prompt ID NAME        point another saved agent at a prompt
```

`/edit prompt [NAME]` and `/edit NAME` are the older spellings of
`/prompt edit` and still work. The name is what the commands take everywhere;
matching is case-insensitive when that leaves exactly one candidate.

## Registering an agent around a prompt

Two lines make a new agent: one for what it should be, one for what it may
use.

```
pmai> /prompt add reviewer You review diffs and list only real defects.
Created system prompt 'reviewer' (no agent uses it yet; /agent prompt ID reviewer or /agent add picks it).
pmai> /agent add reviewer - files,run reviewer
Added agent 'reviewer': openai, tool groups files, run, system prompt 'reviewer'. /agent use reviewer switches this chat to it.
```

`/agent add NAME MODEL GROUPS PROMPT [PROVIDER [BASE_URL]]` takes:

| argument | meaning |
|---|---|
| `NAME` | the agent's id; an existing id is updated in place |
| `MODEL` | a model name, or `-` for the provider's default |
| `GROUPS` | tool groups as `a,b,c` (`/tools` lists them), or `-` for none |
| `PROMPT` | a named system prompt that already exists (`/prompts`) |
| `PROVIDER` | optional; defaults to the current chat's provider |
| `BASE_URL` | optional; with a new `PROVIDER`, registers an OpenAI-compatible endpoint |

The prompt must exist first — that is what makes it *named*: the same text is
never typed into two agents. An unknown tool group or prompt is refused with
the list of known ones, and nothing is saved. Saving does not switch the
chat; `/agent use NAME` does that (and starts the conversation over).

Tool groups are the unit of access. A group maps to the tool names it
contains, and the agent's `toolNames` is the union of its groups, so an agent
sees exactly what its groups give it — whatever its depth in the process
tree, and whether or not it delegates. MCP servers are the exception: their
tools reach every agent while the server is enabled.

## Changing a saved agent

Each of these changes one field, saves the file, updates the live runtime,
and — when the agent is the current chat's — updates the chat in place
without clearing the conversation.

```
/agent tools ID a,b,c        replace its tool groups
/agent tools ID +a,-b        add and remove groups
/agent tools ID -            clear them
/agent model ID MODEL        change its model (- for the provider default)
/agent prompt ID NAME        point it at another named prompt
/agent provider ID PROVIDER  move it to a configured provider
/agents describe ID TEXT     set the purpose a delegating model reads to pick it
/agents enable|disable ID    park it without deleting it
/agent remove ID             drop it; subagent lists and the default agent follow
/edit agent [ID]             everything else, as JSON in $EDITOR
```

`/edit agent` shows the whole definition. Two fields need care: `id` must stay
as it is (`/agent add` creates another agent), and `instructions` is the text
of the prompt named in `systemPrompt`. Changing the text changes that prompt
for every agent using it; naming another existing prompt without touching
the text switches to that prompt; naming a prompt that does not exist creates
it from the text. Limits, `subagentNames`, delegation, streaming, and
generation options are edited there too.

`/agent remove` refuses the current chat's agent — switch first — and says
when the removed agent's prompt is now unused, so `/prompt rm` can follow.
The live runtime forgets the definition immediately; a run already using it
finishes with the copy it was given.

## The other templates

`/prompts` also lists four templates that are not system prompts. Each has a
built-in default; a custom text is saved under `prompts` in the
configuration, and clearing it in the editor restores the default.

| template | used by | must contain | edit with |
|---|---|---|---|
| `compact` | `/chat compact`, and autocompact (`/set ctx.compact N`) with a built-in focus on the task in hand | `{{transcript}}` (`{{focus}}` optional) | `/edit compact` |
| `delegation` | the brief a child agent receives | `{{task}}` (`{{context}}`, `{{output}}`, `{{agent}}`, `{{cwd}}` optional) | `/edit delegation` |
| `worker` | the derived `<agent>.worker` instructions | — | `/edit worker` |
| `memory` | `/memory learn` | `{{transcript}}` (`{{memory}}`, `{{focus}}` optional) | `/edit memory-prompt` |

See `doc/agents.md` for what the delegation and worker templates do.
