---
name: cli
description: Introductory guide to the `gwx` CLI — a multi-account wrapper around Google's `gws` Workspace CLI that enforces explicit per-account selection. Use whenever the user asks for anything involving Gmail, Google Drive, Calendar, Sheets, Docs, Chat, or Admin across multiple Google accounts. Triggers on phrases like "check my email", "search my drive", "what's on my calendar", "send a reply", "across all my accounts".
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

## Discovering services and verbs

`gwx` does not duplicate `gws`'s help. To learn which services and verbs exist,
pass `--help` through to gws via any account:

```
gwx work --help                     # full gws CLI surface
gwx work gmail --help               # one service
gwx work gmail messages --help      # one resource
gwx work gmail +send --help         # a helper
```

This auto-updates as gws ships new APIs. Always run this when you don't know
the exact command — do not guess.

## Read fan-out (the killer feature)

For read-only verbs, `gwx` runs in parallel across multiple accounts and emits
NDJSON, one line per account:

```
gwx all gmail messages list --params '{"q":"q3 review","maxResults":5}'
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
gwx all gmail messages list --params '{"q":"invoice"}' \
  | jq -s 'map(select(.exit==0) | {account, count: (.stdout.messages|length)})'

gwx all calendar +agenda --today \
  | jq -r 'select(.exit==0) | "\(.account): \(.stdout|length) events"'
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
$ gwx gmail messages list
gwx: 'gmail' is not a known account.
gwx: valid accounts: work personal side (or 'all', or 'a,b' comma-list)
gwx: subcommands: init | login | logout | remove | whoami | skills | --help
gwx: did you forget the account? e.g. 'gwx work gmail messages list'
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
