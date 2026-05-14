# gwx

**Multiple Google accounts, one CLI, optimal for Agents.**

A tiny bash wrapper around [`gws`](https://github.com/googleworkspace/cli)
(Google's officially unofficial Workspace CLI). Every call must name an
account — so an agent can never send a personal email from your work
address by accident.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/pA1nD/gwx/main/install.sh | bash
```

That single command sets everything up: it installs `gwx`, adds `gws`
if you don't have it, and prints the next step. Re-run anytime to
update.

## How it works

**See everything at once.** Fan out across every account in parallel:

```bash
gwx all calendar +agenda           # today's events, every account
gwx work,personal gmail +triage    # unread inbox, work + personal
```

Output is one JSON line per account. To pretty-print grouped per account:

```bash
gwx all calendar +agenda | jq -r '"=== \(.account) ===\n\(.stdout)"'
```

Reads on multiple accounts fan out — requests run in parallel. Writes
(e.g. `send`, `create`, `delete`) refuse to run without a single named
account, so you can't accidentally mass-mail from every inbox at once.

**Hand it to an agent.** Ask Claude things like:

```text
> Anything urgent across my inboxes right now? Flag, don't reply.

● I'll scan every inbox in parallel and flag anything that looks urgent.

● Bash(gwx all gmail +triage)
  ⎿  work     → 312 unread, 3 marked urgent
     personal → 87 unread, 1 marked urgent
     side     → 19 unread, all spam

● Bash(gwx work gmail users messages modify ...)        ×3
● Bash(gwx personal gmail users messages modify ...)    ×1
  ⎿  4 threads flagged

● Flagged 4 threads. No replies sent.
  • work: invite — "30 min sync" tomorrow 9am, no agenda (HR + your manager)
  • work: legal — subject "see attached", 9 PDFs, empty body
  • work: AWS billing — monthly spend up 340% (MTD $18,400)
  • personal: mom — "haven't heard from you in a while" (sent Sunday, it's Friday)
```

Or, multi-step:

```text
> What should I know about for my next meeting?

● I'll find your next meeting and check recent threads with the attendees.

● Bash(gwx all calendar +agenda)
  ⎿  work     → 14:00 "Q3 review w/ Acme" (alice@acme.com, bob@acme.com)
     personal → 18:30 "Dinner w/ Sam"
     side     → (nothing today)

● Bash(gwx all gmail users messages list --params '{"q":"from:(alice@acme.com OR bob@acme.com)"}')
  ⎿  work     → 12 threads, latest 2 days ago
     personal → 0 threads
     side     → 0 threads

● Q3 review with Acme at 14:00 — TL;DR:
  • Alice pushed back on enterprise pricing yesterday — wants 15% or annual.
  • Bob asked for the churn deck (still owed).
  • Open from last time: SSO rollout date, contract redlines.
```

And there's a deeper bench: ~95 ready-made workflow skills — `+triage`,
`+meeting-prep`, drive audits, role-based personas — drop into the
agent's project with `gwx skills install`. [More on that below](#powerful-agent-skills).

## Getting started

### 1. Get an OAuth client from Google Cloud Console

You need ONE OAuth client (it can be shared across all your accounts, or you
can create one per account — `gwx init` will ask).

Briefly:

1. Sign in to [console.cloud.google.com](https://console.cloud.google.com) with
   the account that should own the project. (For Workspace-only setups, pick
   the account where you're admin.)
2. **Create a project** (e.g., `gwx-oauth-client`).
3. **Enable APIs** (☰ → APIs & Services → Library):
   Gmail API, Google Drive API, Google Calendar API, Google Sheets API,
   Google Docs API, Google People API.
4. **Configure OAuth consent screen** (APIs & Services → OAuth consent screen):
   - User Type: **External**
   - Add your email(s) as **Test users**
5. **Create OAuth client** (APIs & Services → Credentials → + CREATE CREDENTIALS):
   - Application type: **Desktop app**
   - Copy the **Client ID** and **Client secret**
6. (Workspace admins) **Trust the app** (admin.google.com → Security → Access
   and data control → API controls → Manage App Access →
   - Configure new app → OAuth App Name or Client ID → paste your Client ID →
     Trusted → Continue → Finish). Skip if your org isn't admin-managed by you.

### 2. Add each account

Run `gwx init <name>` once per account. The first time you'll be asked for
your OAuth client; subsequent calls offer to reuse the existing client (or
provide a new one).

```bash
gwx init work
# Prompts for client_id and client_secret (paste from step 5 above)

gwx init personal
# Existing OAuth clients found:
#   1) work
#   n) provide a new client
# → Hit enter (default 1) to reuse work's client

gwx init side
```

### 3. Authenticate each account

```bash
gwx login work
# Opens browser → sign in as work account → click through unverified-app warning
gwx login personal
gwx login side
```

### 4. Verify

```bash
gwx whoami
```

```
Accounts:
  work        ✓  alice@workdomain.com    (14 scopes)
  personal    ✓  alice@personal.com      (14 scopes)
  side        ✓  alice@side.com          (14 scopes)
```

## Why

[`gws`](https://github.com/googleworkspace/cli) itself is brilliant —
agent-first, JSON in/out, dynamically generated from Google's API
Discovery Service. But it's single-account by design (multi-account
support was removed in v0.7.0).

`gwx` adds the multi-account contract on top:

- Explicit per-call account selection (no defaults, no inference).
- Parallel reads with a write-refusal allowlist — agents can't
  accidentally fan out a `send` to every inbox.
- A separate `gwx skills install` command that fetches the ~95 upstream
  gws skills, rewrites them for the multi-account contract, and
  installs them per-project — so heavyweight workflow skills land only
  in the agents that need them, not every Claude Code session.

## Using gwx with agents

> ⚠️ `gwx` gives an agent live read+write access to every account you've
> added — Gmail, Drive, Calendar, Sheets, Docs, People. Sends, shares,
> deletes, and calendar invites are real-world side effects that can't
> be undone. Treat each account in `gwx whoami` like a logged-in browser
> tab and review what the agent is about to do, especially for writes.

Once installed, `gwx` is on your `PATH` — any Claude Code agent can call
it from Bash without further setup (`gwx work gmail users messages list ...`).
The remaining setup below makes agents _fluent_ in the wrapper and
prevents them from sidestepping it.

### Teach agents the gwx contract

Having `gwx` on `PATH` isn't quite enough. Agents don't reach for commands
they don't already know about, and even when they do they tend to use them
naively. The repo ships a small **`gwx:cli` skill** that teaches the
wrapper's contract — "always specify an account; only allowlisted verbs
fan out" — so agents discover the binary, understand the rules, and use
it safely. With the skill loaded, Claude also picks `gwx` up automatically
when you mention your emails, calendar, drive, or other Workspace data —
no need to spell out the command.

**Recommended: per session.** Load the skill only for the sessions that
actually need mail/calendar/drive access:

```bash
claude --plugin-dir ~/.local/share/gwx
```

**Alternative: globally.** Install once and have every Claude Code CLI
session load the skill automatically, via the plugin marketplace (the
gwx repo is its own marketplace):

```
/plugin marketplace add pA1nD/gwx
/plugin install gwx@gwx-marketplace
```

After that, the `gwx:cli` skill is available everywhere — no
`--plugin-dir` flag needed.

### Keeping agents on the wrapper

`gwx`'s account isolation only holds if the agent goes _through_ the
wrapper. If an agent shells out to `gws gmail users messages send ...`
directly, account selection drops out and you're back to whatever
account `gws` defaulted to.

The skill files installed by `gwx skills install` carry the rule
inline: the `gwx-cli` skill has a "Never call `gws` directly" section,
and every rewritten `gws-*` skill is prefixed with a banner that
repeats it. That's the enforcement — instruction-level, not
policy-level.

A `Bash(gws *)` deny rule in `~/.claude/settings.json` looks like
extra defense, but in practice Claude Code's permission classifier
treats `gws` as a substring of `gwx` and blocks legitimate wrapper
calls. The skill-based rule is more reliable. If you still want the
deny as belt-and-braces, add it manually — the installer no longer
prompts for it.

## Powerful Agent Skills

Upstream `gws` ships a deep library of ~95 skills that turn an agent into a
capable Workspace operator: per-API skills (`gws-gmail`, `gws-drive`,
`gws-calendar`, `gws-sheets`, `gws-docs`, `gws-people`, …), end-to-end
**recipes** for concrete workflows (`+triage` an inbox, `+meeting-prep`
from a calendar event, draft-and-send threads, sheet roll-ups, drive
audits), and **personas** that give an agent a working role
(executive assistant, researcher, ops). Together they're the difference
between an agent that knows the API exists and one that can actually run
your Monday morning.

For agents that need that context, install the rewritten skills into the
agent's directory:

```bash
cd ~/path/to/your/agent
gwx skills install                # rewrites + installs gws-* into ./.claude/skills/
```

Subset and variants:

```bash
gwx skills install --skill gws-gmail gws-drive    # subset
gwx skills install --recipes                       # also recipe-* (concrete workflows)
gwx skills install --personas                      # also persona-* (role definitions)
gwx skills install --all                           # everything (~95 skills)

gwx skills uninstall                               # remove all + manifest
gwx skills uninstall --skill <name>...
```

Upstream skills are written for single-account `gws` — every example reads
`gws gmail users messages list ...`. Therefore we rewrite each skill during installation:
`gws X` → `gwx <account> X` , so the agents can follow these skills correctly.

> **Trust note:** `gwx skills install` does a shallow clone of
> [`googleworkspace/cli`](https://github.com/googleworkspace/cli) and
> rewrites the markdown into your project. The rewriter doesn't sandbox
> the content beyond the `gws` → `gwx <account>` substitution — anything
> the upstream skill says to your agent gets passed through. Installing
> skills means trusting `googleworkspace/cli`'s `main` HEAD at clone time.

## Command reference

### Account management

```
gwx init    <name>      add an account (prompts for OAuth, offers reuse)
gwx login   <name>      OAuth flow
gwx logout  <name>      clear credentials (keep alias)
gwx remove  <name>      delete account entirely (alias + creds + client)
gwx whoami              list accounts + auth status
```

### The wrapper

```
gwx <account>   <gws args...>     run against one account
gwx <a,b>       <gws args...>     fan out across listed accounts (read-only)
gwx all         <gws args...>     fan out across every account (read-only)
gwx <account>   --help            pass-through to gws (full CLI surface)
```

### Skills (per-project workflow context)

```
gwx skills install [--skill <names>...] [--recipes] [--personas] [--all]
gwx skills uninstall [--skill <names>...]
```

## Read fan-out vs writes

Multi-account fan-out is gated by an allowlist:

```
list, get, search, schema, +triage, +agenda, +read
```

Anything else — writes, unknown verbs — must target a single account or
`gwx` exits with code 3 and points you at the single-account form. This
prevents "send this email to all 3 accounts" type accidents.

## Discovering services and verbs

`gwx --help` does not duplicate `gws`'s help. However, pass `--help` through with any
account and you get the full, auto-updating gws CLI surface:

```bash
gwx work --help                 # all services
gwx work gmail --help           # one service
gwx work gmail +send --help     # a helper
```

This is the canonical way to learn what's available — there's nothing to
hardcode or memorize.

## How account isolation works

Every `gwx` invocation sets `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` to a
per-account directory under `~/.config/gwx/`, so each account writes to
its own scope:

```
~/.config/gwx/                          (mode 0700)
├── accounts.list                       one alias per line
├── gws_bin                  (0600)     pinned absolute path to gws
└── accounts/
    ├── work/                           (0700)
    │   ├── client.env       (0600)     OAuth client_id + secret (plaintext)
    │   ├── credentials.enc  (0600)     refresh token, AES-256-GCM
    │   └── token_cache.json (0600)     access token, encrypted
    ├── personal/                       (0700)
    └── side/                           (0700)
```

Refresh and access tokens are AES-256-GCM encrypted at rest. The
encryption key lives in your OS secret store — macOS Keychain or Windows
Credential Manager — under one shared entry, `gws-cli/<your-os-user>`.
**All gwx accounts share that single key**; per-account separation comes
from the filesystem (`0700` dirs, `0600` files), not the cipher. On Linux
the keyring path isn't compiled into `gws`, so the key falls back to a
`.encryption_key` file alongside each account's ciphertext.

The OAuth `client_id` / `client_secret` in `client.env` are stored as
plaintext shell-quoted env at mode `0600` — same shape as
`~/.aws/credentials`, `~/.npmrc`, or `~/.kube/config`.

> Run `gwx login` calls one at a time — parallel first-time logins race on the keychain write.

## Exit codes

```
0   success
2   bad usage (missing/unknown account, bad flags)
3   fan-out refused (write/unknown verb)
4   account not authenticated, missing OAuth client, gws/git not installed
*   passed through from gws
```

## Repo layout

```
.
├── .claude-plugin/
│   ├── plugin.json                 plugin manifest (name="gwx" → namespace gwx:*)
│   └── marketplace.json            marketplace manifest (repo IS its own marketplace)
├── bin/gwx                         the wrapper + inline rewriter (single bash file)
├── skills/cli/SKILL.md             the gwx:cli skill
├── install.sh                      unified install/update/uninstall
├── tests/test.sh                   bash test suite (no external deps)
├── README.md
├── LICENSE
└── .gitignore
```

## Develop

```bash
./tests/test.sh                              # 35 tests, runs in seconds
./install.sh install --from-folder .         # install from this clone
./install.sh uninstall                       # preserves ~/.config/gwx
./install.sh uninstall --purge               # also wipes accounts + cache
```

## Status

v0.1.0 — first public tag. Pre-1.0; `gws` itself is also pre-1.0, so expect
occasional churn. PRs welcome.

## License

MIT © 2026 Björn Schmidtke. See [LICENSE](LICENSE).
