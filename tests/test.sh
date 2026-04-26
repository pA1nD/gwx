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

echo
if [[ "$fails" -eq 0 ]]; then
  printf '%sall %d tests passed%s\n' "$c_green" "$total" "$c_reset"
  exit 0
else
  printf '%s%d/%d tests failed%s\n' "$c_red" "$fails" "$total" "$c_reset"
  exit 1
fi
