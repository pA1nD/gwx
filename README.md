# gwx

**Multiple Google accounts, one CLI.**

A tiny bash wrapper around [`gws`](https://github.com/googleworkspace/cli)
(Google's officially unofficial Workspace CLI). Every call must name an
account — so an agent can never send a personal email from your work
address by accident.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/pA1nD/gwx/main/install.sh | bash
```

Installs `gwx` into `~/.local/share/gwx/`, symlinks `~/.local/bin/gwx`,
and auto-installs `gws` via npm if missing. `jq` is recommended for
nicer JSON output. Re-run the same command to update; `./install.sh
uninstall` to remove. For non-interactive and other flags, see
`./install.sh --help`.

## How it works

Every call names the account up front:

```bash
gwx work gmail +triage              # unread inbox for "work"
gwx personal calendar +agenda       # today's events for "personal"
gwx work drive files list           # any gws command, scoped to one account
```

No defaults, no inference — no way to accidentally hit the wrong account.
Discover commands with `gwx <account> --help`; that passes through to
the full auto-updating `gws` CLI surface.

To **fan out** across every account at once, use `all` (or a comma list):

```bash
gwx all gmail +triage                  # every inbox, in parallel
gwx work,personal calendar +agenda     # two specific accounts
```

Fan-out is read-only — `send`, `create`, `delete`, etc. must target a
single account. Output is one JSON line per account, so `jq` slots in
naturally:

```bash
gwx all gmail messages list --params '{"q":"q3 review"}' \
  | jq -s 'map(select(.exit==0) | {account, n: (.stdout.messages|length)})'
```

That single line searches every inbox concurrently and tells you which
account each result came from.

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
it from Bash without further setup (`gwx work gmail messages list ...`).
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

### Block raw `gws` (lock agents to gwx)

`gwx`'s account isolation only holds if the agent goes _through_ the
wrapper. If an agent shells out to `gws gmail messages send ...`
directly, account selection drops out and you're back to whatever
account `gws` defaulted to. Deny `gws` at the permission layer:

```json
{
  "permissions": {
    "deny": ["Bash(gws *)", "Bash(*/gws *)"]
  }
}
```

Drop that into `~/.claude/settings.json` (global) or a project's
`.claude/settings.json` (per-project). The installer offers to add it
for you on install (default Y); skip with `--no-permission-deny` if
you'd rather not. Permissions propagate to subagents, so even delegated
tasks can't bypass the rule.

> **Honest limitation:** the deny is glob-based on the rendered command
> string. It catches the common shapes (`gws ...`, `/usr/local/bin/gws ...`)
> but a determined caller can still bypass it via `bash -c 'gws ...'`,
> `command gws`, `$(which gws) ...`, etc. Treat this as a speed bump that
> stops accidental drift, not as a security boundary.

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
`gws gmail messages list ...`. Therefore we rewrite each skill during installation:
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
