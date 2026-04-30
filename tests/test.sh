#!/usr/bin/env bash
# gwx — test suite. No external deps. Doesn't need gws installed.
# Uses an isolated GWX_HOME under a temp dir so it never touches real config.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GWX="$REPO_DIR/bin/gwx"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GWX_HOME="$TMP/gwx"

c_green=$'\033[32m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'
total=0; fails=0

run() {
  # run gwx and capture combined output + exit
  "$GWX" "$@" 2>&1
}

assert() {
  local desc="$1" expected_exit="$2" expected_substr="$3"; shift 3
  total=$((total + 1))
  local out actual
  out="$(run "$@")"
  actual=$?
  if [[ "$actual" != "$expected_exit" ]]; then
    printf '%sFAIL%s %s\n' "$c_red" "$c_reset" "$desc"
    printf '  exit: got %d, want %s\n' "$actual" "$expected_exit"
    printf '  cmd:  gwx %s\n' "$*"
    printf '%s%s%s\n' "$c_dim" "$out" "$c_reset" | sed 's/^/    /'
    fails=$((fails + 1))
    return
  fi
  if [[ -n "$expected_substr" ]] && ! grep -q -- "$expected_substr" <<<"$out"; then
    printf '%sFAIL%s %s\n' "$c_red" "$c_reset" "$desc"
    printf '  output missing: %s\n' "$expected_substr"
    printf '  cmd:  gwx %s\n' "$*"
    printf '%s%s%s\n' "$c_dim" "$out" "$c_reset" | sed 's/^/    /'
    fails=$((fails + 1))
    return
  fi
  printf '%sok%s   %s\n' "$c_green" "$c_reset" "$desc"
}

# --- pre-init tests (no accounts.list) -----------------------------------------

assert "help with no args"         0 "USAGE"
assert "help via --help"           0 "DISCOVERING GWS"                       --help
assert "help via -h"               0 "FAN-OUT RULES"                         -h
assert "help via 'help'"           0 "EXIT CODES"                            help
assert "empty arg rejected"        2 "empty argument"                       ""
assert "version --version"         0 "gwx"                                  --version
assert "version short -V"          0 "gwx"                                  -V
assert "version positional"        0 "gwx"                                  version
assert "whoami uninitialized"      4 "not initialized"                      whoami
assert "login uninitialized"       4 "not initialized"                      login work
assert "dispatch uninitialized"    4 "not initialized"                      work gmail messages list
assert "init no-args non-tty"      2 "usage: gwx init"                      init
assert "init --help"               0 "USAGE"                                init --help
assert "login --help"              0 "USAGE"                                login --help
assert "logout --help"             0 "USAGE"                                logout --help
assert "remove --help"             0 "USAGE"                                remove --help
assert "whoami --help"             0 "USAGE"                                whoami --help

# --- simulate an initialized state ---------------------------------------------

mkdir -p "$GWX_HOME/accounts/work" "$GWX_HOME/accounts/personal" "$GWX_HOME/accounts/side"
chmod 700 "$GWX_HOME"
printf 'work\npersonal\nside\n' > "$GWX_HOME/accounts.list"

# --- post-init tests -----------------------------------------------------------

assert "forgot account"            2 "did you forget"                       gmail messages list
assert "unknown account typo"      2 "is not a known account"               wrok gmail list
assert "login unknown account"     2 "unknown account"                      login bogus
assert "fan-out write refused (all)"        3 "refusing fan-out"            all gmail +send --to a@b
assert "fan-out write refused (comma)"      3 "refusing fan-out"            work,personal gmail messages create
assert "fan-out unknown verb refused"       3 "refusing fan-out"            all gmail messages batchModify
assert "fan-out write names suggestion"     3 "gwx work gmail +send"        all gmail +send --to a@b
# Positional-only read-verb match (H1 regression). A flag value that happens
# to equal a read verb must not unlock fan-out for an actual write command.
assert "flag value 'list' doesn't unlock fan-out" 3 "refusing fan-out"      all gmail messages send --subject list --to a@b
assert "flag value '+read' doesn't unlock fan-out" 3 "refusing fan-out"     all gmail messages send --body +read --to a@b

# Read-verb fan-out and single-account paths reach the gws-install check.
# If gws isn't installed, exit 4 is expected here. If it IS installed,
# they'll attempt a real call (likely fail with auth error, exit nonzero).
if command -v gws >/dev/null 2>&1; then
  echo "${c_dim}· gws installed; skipping no-gws sanity tests${c_reset}"
else
  assert "fan-out read reaches gws check"   4 "gws not installed"           all gmail messages list
  assert "single-account reaches gws check" 4 "gws not installed"           work gmail +triage
  assert "all --help short-circuits"        4 "gws not installed"           all --help
fi

# --- plugin manifest validation -----------------------------------------------

bump_test() { total=$((total + 1)); }
ok_test()   { printf '%sok%s   %s\n' "$c_green" "$c_reset" "$1"; }
fail_test() { printf '%sFAIL%s %s\n' "$c_red" "$c_reset" "$1"; fails=$((fails + 1)); }

bump_test
if [[ -f "$REPO_DIR/.claude-plugin/plugin.json" ]]; then
  ok_test "plugin.json exists"
else
  fail_test "plugin.json missing"
fi

bump_test
if [[ -f "$REPO_DIR/.claude-plugin/marketplace.json" ]]; then
  ok_test "marketplace.json exists"
else
  fail_test "marketplace.json missing"
fi

if command -v jq >/dev/null 2>&1; then
  bump_test
  if jq -e '.name == "gwx"' "$REPO_DIR/.claude-plugin/plugin.json" >/dev/null 2>&1; then
    ok_test "plugin.json name=gwx"
  else
    fail_test "plugin.json name should be 'gwx'"
  fi
  bump_test
  if jq -e '.plugins[0].name == "gwx"' "$REPO_DIR/.claude-plugin/marketplace.json" >/dev/null 2>&1; then
    ok_test "marketplace.json declares gwx plugin"
  else
    fail_test "marketplace.json should declare gwx plugin"
  fi
fi

bump_test
if [[ -f "$REPO_DIR/skills/cli/SKILL.md" ]]; then
  ok_test "skills/cli/SKILL.md exists"
else
  fail_test "skills/cli/SKILL.md missing"
fi

# --- rewriter round-trip ------------------------------------------------------
# Set up a fake gws repo, point gwx at it, install one skill, verify rewrites.

FAKE_GWS="$TMP/fake-gws"
mkdir -p "$FAKE_GWS/skills/gws-shared" "$FAKE_GWS/skills/gws-test"

cat > "$FAKE_GWS/skills/gws-shared/SKILL.md" <<'FIXTURE'
---
name: gws-shared
description: "gws CLI: Shared patterns."
metadata:
  cliHelp: "gws --help"
---

# Shared

Run `gws auth login` to authenticate.

```bash
gws auth login
```
FIXTURE

cat > "$FAKE_GWS/skills/gws-test/SKILL.md" <<'FIXTURE'
---
name: gws-test
description: A test skill
metadata:
  cliHelp: "gws test --help"
---

# Test

> **PREREQUISITE:** Read `../gws-shared/SKILL.md` first.

Use the `gws` CLI for everything.

## Steps

1. List things: `gws test list --params '{"foo": "bar"}'`
2. Or in a fenced block:

```bash
gws test list
gws test get --id 42
```

3. Tip: 'gws test schema' shows the API shape.
FIXTURE

# Init fake repo as git so `git clone` works
(cd "$FAKE_GWS" && git init -q && git add -A \
  && git -c user.email=t@t -c user.name=t commit -q -m "fixture") || true

# Run gwx skills install with overridden source
TEST_PROJ="$TMP/test-project"
mkdir -p "$TEST_PROJ"

bump_test
GWX_CACHE_DIR="$TMP/test-cache" GWS_REPO_URL="$FAKE_GWS" \
  bash -c "cd '$TEST_PROJ' && '$GWX' skills install --skill gws-test" >"$TMP/install.out" 2>&1
install_exit=$?
if [[ "$install_exit" -ne 0 ]]; then
  fail_test "gwx skills install failed (exit $install_exit)"
  cat "$TMP/install.out" | sed 's/^/    /' >&2
else
  ok_test "gwx skills install --skill gws-test"
fi

# Verify outputs in the test project
GENERATED="$TEST_PROJ/.claude/skills/gws-test/SKILL.md"
SHARED_GENERATED="$TEST_PROJ/.claude/skills/gws-shared/SKILL.md"

bump_test
if [[ -f "$GENERATED" ]]; then ok_test "rewritten gws-test/SKILL.md exists"; else fail_test "rewritten skill missing"; fi

bump_test
if [[ -f "$SHARED_GENERATED" ]]; then ok_test "gws-shared installed as transitive dep"; else fail_test "gws-shared not installed"; fi

bump_test
if [[ -f "$TEST_PROJ/.claude/skills/.gwx-manifest.json" ]]; then
  ok_test "manifest written"
else
  fail_test "manifest missing"
fi

# Content checks
if [[ -f "$GENERATED" ]]; then
  bump_test
  grep -q 'NOTE FOR AGENTS' "$GENERATED" && ok_test "banner injected" || fail_test "banner missing"

  bump_test
  grep -q 'gwx <account> test list' "$GENERATED" && ok_test "fenced code rewritten" || fail_test "fenced code not rewritten"

  bump_test
  grep -q '`gwx <account> test list --params' "$GENERATED" && ok_test "inline backtick rewritten" || fail_test "inline backtick not rewritten"

  bump_test
  grep -q "'gwx <account> test schema'" "$GENERATED" && ok_test "single-quoted prose rewritten" || fail_test "single-quoted prose not rewritten"

  bump_test
  grep -q 'cliHelp: "gwx <account> test --help"' "$GENERATED" && ok_test "cliHelp metadata rewritten" || fail_test "cliHelp not rewritten"

  bump_test
  grep -q '`../gws-shared/SKILL.md`' "$GENERATED" && ok_test "relative skill link preserved" || fail_test "relative link broken"

  bump_test
  grep -q 'the `gws` CLI' "$GENERATED" && ok_test "prose mention of \`gws\` preserved" || fail_test "prose mention rewritten by mistake"
fi

# Skills uninstall
bump_test
GWX_CACHE_DIR="$TMP/test-cache" \
  bash -c "cd '$TEST_PROJ' && '$GWX' skills uninstall" >/dev/null 2>&1 \
  && ok_test "gwx skills uninstall" || fail_test "uninstall failed"

bump_test
[[ ! -d "$TEST_PROJ/.claude/skills/gws-test" ]] && ok_test "gws-test removed" || fail_test "gws-test still present after uninstall"

# --- scoped_env: per-account client.env required ------------------------------
# Fake gws echoes env so we can verify which client got loaded.

FAKE_BIN="$TMP/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gws" <<'FAKE'
#!/usr/bin/env bash
echo "CLIENT_ID=${GOOGLE_WORKSPACE_CLI_CLIENT_ID:-NONE}"
echo "CONFIG_DIR=${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-NONE}"
echo "KEYRING_BACKEND=${GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND:-NONE}"
exit 0
FAKE
chmod +x "$FAKE_BIN/gws"

# foo: has client.env (should load it). bar: no client.env (should error).
mkdir -p "$GWX_HOME/accounts/foo" "$GWX_HOME/accounts/bar"
echo 'GOOGLE_WORKSPACE_CLI_CLIENT_ID=FOO_CLIENT' > "$GWX_HOME/accounts/foo/client.env"
chmod 600 "$GWX_HOME/accounts/foo/client.env"
printf 'foo\nbar\n' > "$GWX_HOME/accounts.list"

bump_test
foo_out=$(PATH="$FAKE_BIN:$PATH" "$GWX" foo dummy-cmd 2>/dev/null)
if grep -q 'CLIENT_ID=FOO_CLIENT' <<<"$foo_out"; then
  ok_test "scoped_env: per-account client.env loaded"
else
  fail_test "scoped_env: foo should use FOO_CLIENT, got: $foo_out"
fi

bump_test
bar_out=$(PATH="$FAKE_BIN:$PATH" "$GWX" bar dummy-cmd 2>&1)
bar_exit=$?
if [[ "$bar_exit" -eq 4 ]] && grep -q 'no OAuth client' <<<"$bar_out"; then
  ok_test "scoped_env: errors when client.env missing"
else
  fail_test "scoped_env: bar should exit 4 with 'no OAuth client', got exit=$bar_exit, output: $bar_out"
fi

# Default: no keyring_backend pref → KEYRING_BACKEND env var unset (gws picks
# its own default, i.e. OS keychain on macOS/Windows).
bump_test
foo_default=$(PATH="$FAKE_BIN:$PATH" "$GWX" foo dummy-cmd 2>/dev/null)
if grep -q 'KEYRING_BACKEND=NONE' <<<"$foo_default"; then
  ok_test "scoped_env: no pref → keyring backend left to gws default"
else
  fail_test "scoped_env: expected KEYRING_BACKEND=NONE, got: $foo_default"
fi

# With per-account keyring_backend=file pref → exported as
# GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND. Per-account is the explicit
# override path.
bump_test
echo 'file' > "$GWX_HOME/accounts/foo/keyring_backend"
chmod 600 "$GWX_HOME/accounts/foo/keyring_backend"
foo_pref=$(PATH="$FAKE_BIN:$PATH" "$GWX" foo dummy-cmd 2>/dev/null)
if grep -q 'KEYRING_BACKEND=file' <<<"$foo_pref"; then
  ok_test "scoped_env: per-account pref=file exported to gws"
else
  fail_test "scoped_env: expected KEYRING_BACKEND=file, got: $foo_pref"
fi
rm -f "$GWX_HOME/accounts/foo/keyring_backend"

# Global pref alone → still exported. This is the typical case (cmd_login
# probes once per machine, writes here, every account benefits).
bump_test
echo 'file' > "$GWX_HOME/keyring_backend"
chmod 600 "$GWX_HOME/keyring_backend"
foo_global=$(PATH="$FAKE_BIN:$PATH" "$GWX" foo dummy-cmd 2>/dev/null)
if grep -q 'KEYRING_BACKEND=file' <<<"$foo_global"; then
  ok_test "scoped_env: global pref=file exported to gws"
else
  fail_test "scoped_env: expected KEYRING_BACKEND=file from global pref, got: $foo_global"
fi
rm -f "$GWX_HOME/keyring_backend"

# --- cmd_login: auto-fallback on OS keychain failure --------------------------
# Fake `gws auth login` that mimics the macOS keychain failure on the first
# call (no env var set) and succeeds on the second (env var=file). Verifies
# the wrapper detects the pattern, retries, persists the pref, AND that the
# OAuth URL prompt was streamed live (not buffered until after exit).

FAKE_LOGIN="$TMP/fake-login"
mkdir -p "$FAKE_LOGIN"
cat > "$FAKE_LOGIN/gws" <<'FAKE'
#!/usr/bin/env bash
# Mark on disk that we ran, so the test can confirm a 2nd invocation occurred.
echo "$GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND" >> "$GWX_TEST_GWS_LOG"
echo "Open this URL: https://example.com/auth"   # live URL prompt (stderr)
if [[ "${GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND:-}" == "file" ]]; then
  echo "✓ logged in (file backend)"
  exit 0
fi
echo "OAuth flow failed: Error while setting token in cache: OS keyring failed: Platform secure storage failure: An internal error has occurred." >&2
exit 1
FAKE
chmod +x "$FAKE_LOGIN/gws"

# Hide host codesign so the pre-probe can't see the real gws binary signature
# during these tests — we want to exercise the post-failure fallback path
# specifically. PROBE_BIN with no codesign = probe returns 1 = fallback runs.
PROBE_BIN="$TMP/probe-bin"
mkdir -p "$PROBE_BIN"

bump_test
GWX_TEST_GWS_LOG="$TMP/gws-calls.log"
: > "$GWX_TEST_GWS_LOG"
export GWX_TEST_GWS_LOG
login_out=$(PATH="$PROBE_BIN:$FAKE_LOGIN:$PATH" "$GWX" login foo 2>&1)
login_exit=$?
calls=$(wc -l < "$GWX_TEST_GWS_LOG" | tr -d ' ')
pref_val="$(cat "$GWX_HOME/keyring_backend" 2>/dev/null || echo MISSING)"
if [[ "$login_exit" -eq 0 ]] \
   && [[ "$calls" == "2" ]] \
   && grep -q 'falling back to file-based key storage' <<<"$login_out" \
   && grep -q 'Open this URL' <<<"$login_out" \
   && [[ "$pref_val" == "file" ]]; then
  ok_test "cmd_login: post-failure fallback (retries + persists global pref)"
else
  fail_test "cmd_login fallback failed. exit=$login_exit calls=$calls pref=$pref_val output=$login_out"
fi
rm -f "$GWX_HOME/keyring_backend"

# Re-run with global pref already set: must NOT retry, must use file backend
# on first try (single-call path — the typical case after a fresh install).
bump_test
echo 'file' > "$GWX_HOME/keyring_backend"
chmod 600 "$GWX_HOME/keyring_backend"
: > "$GWX_TEST_GWS_LOG"
login_out2=$(PATH="$PROBE_BIN:$FAKE_LOGIN:$PATH" "$GWX" login foo 2>&1)
login_exit2=$?
calls2=$(wc -l < "$GWX_TEST_GWS_LOG" | tr -d ' ')
if [[ "$login_exit2" -eq 0 ]] \
   && [[ "$calls2" == "1" ]] \
   && ! grep -q 'falling back' <<<"$login_out2"; then
  ok_test "cmd_login: existing global pref → single-call path"
else
  fail_test "cmd_login pref-skip failed. exit=$login_exit2 calls=$calls2 output=$login_out2"
fi
rm -f "$GWX_HOME/keyring_backend"

# Pre-probe path: faked uname=Darwin + codesign reports adhoc → probe fires,
# global pref written, gws called ONCE with file backend (no double-flow).
bump_test
PROBE_BIN2="$TMP/probe-bin2"
mkdir -p "$PROBE_BIN2"
cat > "$PROBE_BIN2/uname" <<'U'
#!/usr/bin/env bash
[[ "$1" == "-s" ]] && echo "Darwin" || /usr/bin/uname "$@"
U
cat > "$PROBE_BIN2/codesign" <<'C'
#!/usr/bin/env bash
echo "Signature=adhoc" >&2
exit 0
C
chmod +x "$PROBE_BIN2/uname" "$PROBE_BIN2/codesign"

: > "$GWX_TEST_GWS_LOG"
login_out3=$(PATH="$PROBE_BIN2:$FAKE_LOGIN:$PATH" "$GWX" login foo 2>&1)
login_exit3=$?
calls3=$(wc -l < "$GWX_TEST_GWS_LOG" | tr -d ' ')
pref_val3="$(cat "$GWX_HOME/keyring_backend" 2>/dev/null || echo MISSING)"
if [[ "$login_exit3" -eq 0 ]] \
   && [[ "$calls3" == "1" ]] \
   && grep -q 'Detected ad-hoc-signed gws binary' <<<"$login_out3" \
   && [[ "$pref_val3" == "file" ]]; then
  ok_test "cmd_login: pre-probe detects adhoc-signed gws → single flow"
else
  fail_test "cmd_login pre-probe failed. exit=$login_exit3 calls=$calls3 pref=$pref_val3 output=$login_out3"
fi
rm -f "$GWX_HOME/keyring_backend"
unset GWX_TEST_GWS_LOG

echo
if [[ "$fails" -eq 0 ]]; then
  printf '%sall %d tests passed%s\n' "$c_green" "$total" "$c_reset"
  exit 0
else
  printf '%s%d/%d tests failed%s\n' "$c_red" "$fails" "$total" "$c_reset"
  exit 1
fi
