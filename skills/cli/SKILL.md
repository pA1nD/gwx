---
name: cli
description: |
  Google Workspace operations across multiple accounts via the `gwx` CLI
  (Gmail, Calendar, Drive, Docs, Sheets, Tasks, Chat, People, Admin).

  USE THIS SKILL WHEN the user asks about — even tangentially — any of:

  • Meetings or calls: "my next meeting", "next call", "tomorrow's
    schedule", "who's on the call", "Blitzhash call", "Q3 review",
    "prep for X", "what's on my calendar", attendees, RSVPs.
  • Email / inbox / threads: "did anyone email about X", "the thread
    with Alice", "follow up with Bob", "draft a reply", "search my
    inbox for Y", anything resembling correspondence or reply needs.
  • Action items / todos / pending work that *aren't explicitly tied
    to a local tracker (kanban, GitHub, Linear, etc.)*. Most action
    items in a working person's life live in **email threads and
    meeting invites**, not on a board. If the user says "todos for
    my X call" or "what do I owe people" or "what's pending with Y",
    SEARCH GMAIL + CALENDAR FIRST — do not declare nothing found
    until you've checked at least the relevant Gmail thread and the
    calendar event's attendee list.
  • Drive / Docs / Sheets: finding a doc, reading a sheet, sharing a
    file, or anything resembling "the file Alice sent me" or "the
    spreadsheet from last quarter".
  • Cross-account questions: "across my accounts", "in any inbox",
    "on any calendar", "from my work account", "personal email" —
    any time multiple Google identities are in play.
  • Anyone's contact info, response status, or scheduling intent for
    upcoming events — that's `calendar events list` (attendees) and
    `people` API territory.

  This skill teaches the wrapper's contract (always name an account;
  reads fan out in parallel; writes refuse fan-out). It does NOT
  duplicate Google Workspace API help — for that, use the wrapper's
  `--help` passthrough as documented inside.
---

# gwx — multi-account Google Workspace via gws

`gwx` is a thin wrapper around `gws` (the Google Workspace CLI). It manages
multiple Google accounts and forces you to say which one you mean for every
single call. There is no default account. **You must specify.**

## The one rule

Every `gwx` call starts with an account specifier as the first positional arg.
There is no inference. There is no default.

```
gwx <account>     <gws args...>     # one account
gwx <a,b>         <gws args...>     # comma-list, parallel, read-only
gwx all           <gws args...>     # every configured account, parallel, read-only
gwx <subcommand>  [args]            # init | login | logout | remove | whoami | skills | --help
```

If you forget the account, the call fails with exit 2 and tells you what to type.

## Orientation in one call

`gwx --help` shows both the wrapper's contract **and** the configured account
names at the bottom under `CONFIGURED ACCOUNTS`. That's your single bootstrap
call — you don't need a separate `gwx whoami` just to learn which accounts
exist. (Use `whoami` only when you need auth status: ✓/✗/expired per account.)

**Don't probe for installation.** If you're reading this skill, `gwx` is on
the agent's `PATH`. Never run `which gwx`, `which gws`, `gws --version`, or
any compound command containing the word `gws` — direct `gws` calls are
deny'd by permission policy (the wrapper is the only sanctioned entry
point) and even `which gws` chained with `;` will be rejected as a side
effect. If `gwx --help` errors with "command not found", *then* report it
back — but don't pre-flight check.

## Discovering services and verbs

`gwx` does not duplicate `gws`'s help. To learn which services and verbs exist,
pass `--help` through to gws via any account:

```
gwx <a> --help                           # full gws CLI surface
gwx <a> gmail --help                     # one service
gwx <a> gmail users messages --help      # one resource (note: nested under users)
gwx <a> gmail +send --help               # a helper
```

This auto-updates as gws ships new APIs. Always run this when you don't know
the exact command — do not guess.

## Common command paths (memorize, don't rediscover)

`gws` nests some resources in non-obvious places. The most common gotcha:
**Gmail's `messages` and `threads` resources are nested under `users`.**

| Want to do | Right path | Common wrong guess |
|---|---|---|
| List Gmail messages | `gmail users messages list` | ~~`gmail messages list`~~ |
| Get a Gmail thread | `gmail users threads get` | ~~`gmail threads get`~~ |
| Modify Gmail labels | `gmail users messages modify` | ~~`gmail messages modify`~~ |
| List calendar events | `calendar events list` | (this one IS top-level) |
| Today's agenda | `calendar +agenda --today` | helper, no resource path |
| Inbox triage | `gmail +triage` | helper, no resource path |
| Read one Gmail message | `gmail +read --id <messageId>` | use the helper, not `messages get` |
| List Drive files | `drive files list` | top-level |
| Read sheet values | `sheets spreadsheets values get` | nested under `spreadsheets` |
| List task lists | `tasks tasklists list` | top-level |

If you guess wrong, gws errors with `unrecognized subcommand '<x>'` (exit 3).
Recover with `gwx <account> <service> --help` — but try to use the table above
first, it saves a round-trip.

### Piping output to JSON parsers

`gwx <single-account> <command>` writes JSON to **stdout** and informational
text (auth errors, validation messages) to **stderr**. When piping to `jq` or
`python3 -c`, **don't merge stderr** — that interleaves text into the JSON
stream and breaks the parser:

```bash
# Good — pipe stdout only
gwx pa1nd gmail users threads get --params '{...}' | jq '.messages[].snippet'

# Bad — 2>&1 merges errors into the JSON stream
gwx pa1nd gmail users threads get --params '{...}' 2>&1 | jq ...
```

If you need to see errors AND parse JSON, redirect stderr to a file:

```bash
gwx pa1nd ... 2>/tmp/err.log | jq ...   # then cat /tmp/err.log if needed
```

## Email — the basics you'll do every time

### Search

Gmail's `q` parameter takes the same syntax as Gmail's web search bar. Compose it.

```bash
# By keyword
gwx <a> gmail users messages list --params '{"userId":"me","q":"q3 review","maxResults":15}'

# By sender (also: to:, cc:, bcc:)
gwx <a> gmail users messages list --params '{"userId":"me","q":"from:alice@acme.com","maxResults":10}'

# By recency
gwx <a> gmail users messages list --params '{"userId":"me","q":"newer_than:7d","maxResults":20}'

# Combine — the typical real query
gwx <a> gmail users messages list --params \
  '{"userId":"me","q":"from:alice@acme.com newer_than:30d \"Q3 review\"","maxResults":15}'

# Across all accounts in parallel
gwx all gmail users messages list --params '{"userId":"me","q":"invoice newer_than:14d","maxResults":10}'
```

Useful operators inside `q`: `from:` `to:` `cc:` `subject:` `has:attachment` `is:unread`
`is:starred` `label:<name>` `newer_than:7d` `older_than:1m` `"exact phrase"` `OR` `-` (NOT).

### Whole threads (preferred over per-message reads)

`messages list` returns IDs; reading every message individually is wasteful. Pull the
**thread** instead — one call returns all messages in the conversation:

```bash
# 1) Find threads matching a query
gwx <a> gmail users threads list --params '{"userId":"me","q":"blitzhash","maxResults":10}'

# 2) Fetch one full thread (use the threadId from step 1, or any messageId — they share IDs)
gwx <a> gmail users threads get --params '{"userId":"me","id":"<threadId>","format":"full"}'
```

`format` options: `minimal` (just metadata) | `metadata` (headers only) | `full` (decoded
body) | `raw` (RFC822). Use `metadata` to scan, `full` to read.

For a single message, the `+read` helper is friendlier: `gwx <a> gmail +read --id <id>`.

## Calendar — the basics you'll do every time

### Upcoming events with attendees

`+agenda` is great for a quick today/tomorrow human-readable view but **omits attendees**.
For real prep work, hit `events list` directly — the response includes the full
`attendees[]` array with email, displayName, and responseStatus.

```bash
# Next N events from now, with attendees
gwx <a> calendar events list --params '{
  "calendarId":"primary",
  "timeMin":"2026-04-26T00:00:00Z",
  "timeMax":"2026-05-03T00:00:00Z",
  "singleEvents":true,
  "orderBy":"startTime",
  "maxResults":20
}'

# Filter by keyword in title/description
gwx <a> calendar events list --params '{
  "calendarId":"primary",
  "q":"Blitzhash",
  "timeMin":"2026-04-26T00:00:00Z",
  "timeMax":"2026-05-03T00:00:00Z",
  "singleEvents":true
}'

# Same fan-out across every account
gwx all calendar events list --params '{
  "calendarId":"primary",
  "timeMin":"2026-04-26T00:00:00Z",
  "timeMax":"2026-04-27T00:00:00Z",
  "singleEvents":true,
  "orderBy":"startTime"
}'
```

Each event has `.attendees[]` like `{"email":"alice@acme.com","responseStatus":"accepted","organizer":true}`.
That's the field you want for "who's on this meeting" or "draft email to the attendees".

### Quick views (when attendees aren't needed)

```bash
gwx <a> calendar +agenda --today
gwx <a> calendar +agenda --tomorrow
gwx <a> calendar +agenda --date 2026-04-27
gwx all calendar +agenda --today | jq -r '"=== \(.account) ===\n\(.stdout)"'
```

## Workflow: load recent inbox as context

Broad prompts ("what's on my plate?", "what'd I miss this week?", "anything
important hiding in my inbox?") need a wide slice of metadata, not 5 narrow
searches. The model has the context window for hundreds of (sender, subject,
date, snippet) tuples — feed it that and it'll spot patterns a targeted
query would miss.

**The right signal is `in:inbox`, not `is:unread`.** A read email still in
the inbox = the user has seen it but hasn't acted, archived, or deleted it.
Those are the pending items. `+triage` only shows unread — useful for "is
anything new?" but a poor proxy for "what's pending."

**Pattern: thread metadata for what's currently in the inbox**

Two calls plus N parallel reads:

```bash
# Step 1 — get thread IDs currently in inbox (read or unread):
gwx pa1nd gmail users threads list --params \
  '{"userId":"me","q":"in:inbox newer_than:14d","maxResults":150}'

# Step 2 — for each threadId, fetch metadata only (no bodies). Issue these
# as parallel Bash calls in one turn so they all run concurrently:
gwx pa1nd gmail users threads get --params \
  '{"userId":"me","id":"<id1>","format":"metadata","metadataHeaders":["Subject","From","To","Date"]}'
gwx pa1nd gmail users threads get --params \
  '{"userId":"me","id":"<id2>","format":"metadata","metadataHeaders":["Subject","From","To","Date"]}'
# ... (batch ~20-30 in one turn; Claude Code will run them in parallel)
```

That gives you sender / recipient / subject / date / snippet for every
inbox-resident thread — usually a few thousand tokens — without any body
text. From there, identify the threads that need a `format:"full"` read and
only fetch those.

Variations on `q:`:
- `in:inbox` — currently in the inbox (read or unread). The default for "what's pending."
- `in:inbox is:starred` — narrow to starred-and-still-in-inbox.
- `in:inbox is:unread` — same as `+triage`, just unread.
- `in:inbox newer_than:7d` — recent inbox only (drops crusty old stuff).
- `in:inbox -from:noreply -from:no-reply` — drop bot/notification noise.

**`+triage` still has a use:** quick "anything new?" check. Single call,
already human-formatted. Just don't mistake it for a complete plate view —
read-but-pending items are invisible to it.

```bash
gwx pa1nd gmail +triage --max 50              # unread only — quick "new?"
```

**Don't** use bulk loading for narrow lookups ("the email from Alice about
Q3"). For those, search with `q:"from:alice subject:Q3"` and pull just that
thread.

## Workflow: meeting / call prep ("what do I owe for my <X> call?")

This is the canonical multi-source synthesis prompt. Don't do it with a single
keyword search — you'll miss the recap email almost every time, because recap
emails rarely contain the meeting's nickname literally. Use this 4-step
recipe:

1. **Find the event AND its organizer.** The organizer's email is the most
   reliable way to find the recap thread.
   ```bash
   gwx all calendar events list --params '{
     "calendarId":"primary",
     "q":"<meeting name>",
     "timeMin":"<now ISO>",
     "timeMax":"<now+30d ISO>",
     "singleEvents":true,
     "orderBy":"startTime"
   }'
   ```
   The result includes `attendees[]: [{email, organizer, responseStatus}]`.
   Note the organizer's email and your own RSVP state.

2. **Search emails BY ORGANIZER, not by topic.** Recap subjects often differ
   from the meeting's nickname (e.g. meeting called "Blitzhash" but recap is
   subject "Blitz Tasks 20/04"). Cast a wider net:
   ```bash
   gwx <account> gmail users threads list --params '{
     "userId":"me",
     "q":"from:<organizer-email> OR to:<organizer-email> newer_than:30d",
     "maxResults":15
   }'
   ```
   In parallel, also try the topic keyword as a fallback — but **do both**,
   don't pick just one.

3. **Pull the most recent thread(s) in full** (not message-by-message):
   ```bash
   gwx <account> gmail users threads get --params \
     '{"userId":"me","id":"<threadId>","format":"full"}'
   ```
   One call per thread — read the bodies, look for "tasks", "todos", "action
   items", date words, names of attendees being asked to do things.

4. **Cross-reference back.** If the recap mentions a doc / sheet / Notion
   link, follow it (`drive files list` or just visit). If it names other
   attendees as owners, separate "your todos" from "others'" in the answer.

**Why this beats keyword-only search:** the organizer's email is a stable
identifier; meeting nicknames drift across emails, docs, and calendar titles.
Always pivot through the organizer when an event is in play.

## Parallelize independent calls

Two layers of parallelism are available — use both.

**Layer 1 — fan-out across accounts** (handled by `gwx`): `gwx all <args>` runs
one gws call per account concurrently. You already do this when you write
`gwx all`.

**Layer 2 — multiple gwx invocations at once** (handled by you, the agent):
issue multiple Bash tool calls in a single turn whenever the calls are
independent. Claude Code runs them in parallel. This is a big win for:

- **Multi-strategy search** — searching by topic AND by organizer in the
  same turn, rather than running one and waiting.
  ```bash
  # Issue both as parallel Bash calls in one turn:
  gwx all gmail users threads list --params '{"q":"blitzhash newer_than:30d"}'
  gwx all gmail users threads list --params '{"q":"from:mnrigas@gmail.com newer_than:30d"}'
  ```
- **Multi-surface lookup** — gmail + calendar + drive for the same topic, all
  at once.
  ```bash
  gwx all gmail users threads list --params '{"q":"<topic>"}'
  gwx all calendar events list --params '{"q":"<topic>", ...}'
  gwx all drive files list --params '{"q":"name contains '\''<topic>'\''", ...}'
  ```
- **Reading multiple threads** — once you've identified N candidate thread
  IDs, fetch all N in parallel rather than one after another.
  ```bash
  gwx pa1nd gmail users threads get --params '{"id":"thread-1","format":"full"}'
  gwx pa1nd gmail users threads get --params '{"id":"thread-2","format":"full"}'
  gwx pa1nd gmail users threads get --params '{"id":"thread-3","format":"full"}'
  ```

**Caveat:** parallel Bash calls share fate — if one errors loudly, the others
may be cancelled. Make sure each call is well-formed before batching (correct
path, valid JSON, matched quoting). If you've never run this exact shape
before, run *one* first to validate, then batch the rest.

When NOT to parallelize: when later calls depend on earlier output (e.g.,
calendar events list → extract organizer email → search gmail). Those have
to be sequential.

## Read fan-out (the killer feature)

For read-only verbs, `gwx` runs in parallel across multiple accounts and emits
NDJSON, one line per account:

```
gwx all gmail users messages list --params '{"q":"q3 review","maxResults":5}'
```

```jsonl
{"account":"work","exit":0,"duration_ms":412,"stdout":{"messages":[…]}, "stderr":""}
{"account":"personal","exit":0,"duration_ms":389,"stdout":{"messages":[]}, "stderr":""}
{"account":"side","exit":0,"duration_ms":501,"stdout":{"messages":[…]}, "stderr":""}
```

Allowed read verbs (anything else is rejected for fan-out):
**`list`, `get`, `search`, `schema`, `+triage`, `+agenda`, `+read`**

Use jq freely:

```bash
gwx all gmail users messages list --params '{"q":"invoice"}' \
  | jq -s 'map(select(.exit==0) | {account, count: (.stdout.messages|length)})'

# Pretty-print fan-out results grouped by account (works for any helper):
gwx all calendar +agenda --today | jq -r '"=== \(.account) ===\n\(.stdout)"'
```

## Writes are single-account, period

Any verb not in the read allowlist must target one account. The wrapper refuses
fan-out for writes (exit 3). This is by design — it prevents sending an email
from the wrong account.

```
gwx work gmail +send --to alice@... --subject "..." --body "..."
gwx personal calendar events insert --json '{...}'
gwx side drive +upload ./report.pdf
```

When the user asks for a write, **make sure you know which account they mean**.
If unclear, ask. Never default to one.

## Error patterns and how to recover

The wrapper's errors all start with `gwx:` on stderr and tell you the next move.

| Exit | Meaning | Recovery |
|---|---|---|
| 2 | missing/unknown account, bad flags | use one of the listed accounts as first arg |
| 3 | fan-out refused (write or unknown verb) | re-run with a single account |
| 4 | account not authenticated, missing OAuth client, or `gws`/`git` missing | `gwx init <name>`, `gwx login <name>`, or install `gws`/`git` |
| other | passed through from gws | read gws stderr, fix args |

Examples:

```
$ gwx gmail users messages list
gwx: 'gmail' is not a known account.
gwx: valid accounts: work personal side (or 'all', or 'a,b' comma-list)
gwx: subcommands: init | login | logout | remove | whoami | skills | --help
gwx: did you forget the account? e.g. 'gwx work gmail users messages list'
```

```
$ gwx all gmail +send --to a@b.c --subject hi --body hi
gwx: refusing fan-out for non-read command across 3 accounts.
gwx: fan-out is allowed only when args contain a read verb: list get search schema +triage +agenda +read
gwx: for writes/unknown verbs, target a single account, e.g.:
gwx:   gwx work gmail +send --to a@b.c --subject hi --body hi
```

## Setup (only relevant if `gwx whoami` shows missing accounts)

Run `gwx init <name>` once per account. The first call prompts for OAuth
client_id + secret; subsequent calls offer to reuse the existing client.

```
gwx init work               # prompt: paste client_id + secret from Cloud Console
gwx init personal           # prompt: reuse 'work'? [Y/n]
gwx init side               # ditto
gwx login work              # OAuth browser flow per account
gwx login personal
gwx login side
gwx whoami                  # confirms each account
```

To remove an account entirely (alias + creds + OAuth client): `gwx remove <name>`.
To clear creds only and keep the alias for re-auth: `gwx logout <name>`.

## Skills installation (per agent dir)

If the user is working inside a specific agent directory and asks for rich
Google Workspace workflow context (e.g., recipes, helper commands, +triage
flows), `gwx skills install` writes rewritten gws skills into that project's
`./.claude/skills/`. Only run this when explicitly asked — it's per-project
and shouldn't fire by default.

```
gwx skills install               # all gws-* skills into current project
gwx skills install --recipes     # also recipe-* (concrete workflows)
gwx skills install --personas    # also persona-* (role definitions)
gwx skills install --all         # everything (~95 skills)
gwx skills uninstall             # remove all + manifest
```

## Things to remember

- **Always specify the account.** No defaults. No guessing.
- **Reads can fan out**, writes cannot.
- **Output is NDJSON** for fan-out — pipe through jq.
- **Discover commands via `gwx <account> --help`**, not by recall.
- **Replies/forwards** need to know which account the original was on — when
  reading via `all`, the NDJSON tags each line with `account:` for exactly
  this reason. Use that tag when constructing the write back.
