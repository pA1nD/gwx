#!/usr/bin/env bash
# gwx — unified installer.
#
# USAGE
#   ./install.sh install   [opts]    install gwx (default verb)
#   ./install.sh update    [opts]    update an existing install
#   ./install.sh uninstall [--purge] uninstall gwx (preserves ~/.config/gwx by default)
#
# REMOTE INSTALL (curl | bash)
#   curl -fsSL https://raw.githubusercontent.com/pA1nD/gwx/main/install.sh | bash
#
# DEV INSTALL (from a local clone)
#   cd /path/to/gwx && ./install.sh install --from-folder .
#
# OPTIONS
#   --from-folder PATH        install from a local folder (skips git clone)
#   --prefix DIR              install code at DIR (default: ~/.local/share/gwx)
#   --bin-dir DIR             symlink binary into DIR (default: ~/.local/bin)
#   --version REF             git ref to install (branch/tag/commit, default: main)
#   --non-interactive         no prompts, take all defaults
#   --with-gws | --no-gws     install gws via npm (or skip), no prompt
#   --with-permission-deny    add 'Bash(gws *)' deny to user settings.json
#   --no-permission-deny      skip the deny prompt
#   --purge                   uninstall: also wipe ~/.config/gwx (asks for confirm)
#   -h, --help                show this help
#
# Files preserved across reinstalls: ~/.config/gwx/ (your accounts) and
# ~/.cache/gwx/ (gws skills source clone).

set -euo pipefail

GWX_REPO_URL="${GWX_REPO_URL:-https://github.com/pA1nD/gwx}"
GWX_VERSION="${GWX_VERSION:-main}"
GWX_PREFIX="${GWX_PREFIX:-$HOME/.local/share/gwx}"
GWX_BIN_DIR="${GWX_BIN_DIR:-$HOME/.local/bin}"
GWX_CONFIG_DIR="${GWX_CONFIG_DIR:-$HOME/.config/gwx}"

# When piped from curl|bash, BASH_SOURCE[0] is unset and there's no
# local script dir to auto-detect. Leave SCRIPT_DIR empty in that case.
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'
ok()   { printf '%s✓%s %s\n' "$c_green"  "$c_reset" "$*"; }
warn() { printf '%s!%s %s\n' "$c_yellow" "$c_reset" "$*"; }
note() { printf '%s· %s%s\n' "$c_dim"    "$*"       "$c_reset"; }
err()  { printf 'install: %s\n' "$*" >&2; }
die()  { err "$1"; exit "${2:-1}"; }
have() { command -v "$1" >/dev/null 2>&1; }

print_install_help() { sed -n '2,28p' "$0" | sed -E 's/^# ?//'; }

# --- arg parsing ---------------------------------------------------------------

FROM_FOLDER=""
NON_INTERACTIVE=0
WITH_GWS="ask"
WITH_PERMISSION_DENY="ask"
PURGE=0

# First positional is the verb
VERB="${1:-install}"
case "$VERB" in
  install|update|uninstall) [[ $# -gt 0 ]] && shift || true ;;  # don't shift if VERB defaulted
  -h|--help|help) print_install_help; exit 0 ;;
  --*) VERB="install" ;;        # if a flag was passed first, default to install
  '') VERB="install" ;;
  *) die "unknown verb '$VERB' (try: install | uninstall | update | --help)" 2 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-folder)          FROM_FOLDER="$2"; shift 2 ;;
    --prefix)               GWX_PREFIX="$2"; shift 2 ;;
    --bin-dir)              GWX_BIN_DIR="$2"; shift 2 ;;
    --version)              GWX_VERSION="$2"; shift 2 ;;
    --non-interactive)      NON_INTERACTIVE=1; shift ;;
    --with-gws)             WITH_GWS=yes; shift ;;
    --no-gws)               WITH_GWS=no; shift ;;
    --with-permission-deny) WITH_PERMISSION_DENY=yes; shift ;;
    --no-permission-deny)   WITH_PERMISSION_DENY=no; shift ;;
    --purge)                PURGE=1; shift ;;
    -h|--help)              print_install_help; exit 0 ;;
    *) die "unknown flag: $1 (run './install.sh --help')" 2 ;;
  esac
done

# Default --from-folder if invoked from inside a clone
if [[ -z "$FROM_FOLDER" && -f "$SCRIPT_DIR/.claude-plugin/plugin.json" ]]; then
  FROM_FOLDER="$SCRIPT_DIR"
fi

# --- helpers -------------------------------------------------------------------

prompt_yn() {
  local msg="$1" default="${2:-n}" reply
  if [[ "$NON_INTERACTIVE" -eq 1 || ! -t 0 ]]; then
    [[ "$default" == y || "$default" == yes ]] && echo yes || echo no
    return
  fi
  read -rp "$msg " reply || true
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]] && echo yes || echo no
}

stage_source() {
  # Stage on the same filesystem as the install prefix so the final swap can
  # be a single atomic mv. /tmp is often a different filesystem (tmpfs/APFS
  # snapshot), which would silently degrade mv to cp+rm and break atomicity.
  mkdir -p "$(dirname "$GWX_PREFIX")"
  STAGE="$(mktemp -d "$GWX_PREFIX.staging.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  if [[ -n "$FROM_FOLDER" ]]; then
    note "staging from folder: $FROM_FOLDER"
    have rsync || die "rsync not installed (needed for --from-folder)" 4
    rsync -a --exclude='.git' --exclude='node_modules' \
          --exclude='*.bak.*' --exclude='/tests/.tmp/' "$FROM_FOLDER/" "$STAGE/"
  else
    note "cloning $GWX_REPO_URL @ $GWX_VERSION"
    have git || die "git not installed" 4
    git clone --depth 1 --branch "$GWX_VERSION" "$GWX_REPO_URL" "$STAGE" >/dev/null 2>&1 \
      || die "git clone failed (set GWX_REPO_URL or use --from-folder)" 4
    rm -rf "$STAGE/.git"
  fi
  [[ -f "$STAGE/.claude-plugin/plugin.json" ]] || die "staged source has no .claude-plugin/plugin.json" 4
  [[ -x "$STAGE/bin/gwx" || -f "$STAGE/bin/gwx" ]] || die "staged source has no bin/gwx" 4
}

install_gws() {
  if have npm; then
    note "running: npm install -g @googleworkspace/cli"
    npm install -g @googleworkspace/cli && { ok "gws installed"; return 0; }
    warn "npm install failed"; return 1
  fi
  if have brew; then
    note "running: brew install googleworkspace-cli"
    brew install googleworkspace-cli && { ok "gws installed"; return 0; }
    warn "brew install failed"; return 1
  fi
  warn "no supported package manager (npm or brew)"; return 1
}

add_permission_deny() {
  local settings="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  if ! have jq; then
    warn "jq not installed — skipping permission deny"
    note "add manually: \"permissions\": { \"deny\": [\"Bash(gws *)\"] } in $settings"
    return 1
  fi
  if [[ ! -f "$settings" ]]; then
    echo '{}' > "$settings"
  fi
  # mktemp gives us an unguessable temp path beside the target — kills
  # the symlink-race that a predictable "$settings.tmp.$$" would invite.
  local tmp; tmp=$(mktemp "$settings.XXXXXX")
  jq '.permissions.deny = ((.permissions.deny // []) + ["Bash(gws *)", "Bash(*/gws *)"] | unique)' "$settings" > "$tmp" \
    && mv "$tmp" "$settings" \
    && ok "added gws deny rules to $settings"
}

# --- verbs ---------------------------------------------------------------------

cmd_install() {
  echo "gwx ${VERB}er"
  echo "  prefix:  $GWX_PREFIX"
  echo "  bin dir: $GWX_BIN_DIR"
  echo "  source:  ${FROM_FOLDER:-$GWX_REPO_URL @ $GWX_VERSION}"
  echo

  stage_source

  # Atomic swap: stage is already on the same filesystem (see stage_source).
  # Move the old prefix aside, mv stage into place, then delete the old copy.
  # The instant the second mv lands, callers see the fully-formed new install
  # — no window where bin/gwx is missing or partially written.
  chmod +x "$STAGE/bin/gwx" 2>/dev/null || true
  local OLD=""
  if [[ -d "$GWX_PREFIX" ]]; then
    OLD="$GWX_PREFIX.old.$$"
    mv "$GWX_PREFIX" "$OLD"
  fi
  mv "$STAGE" "$GWX_PREFIX"
  trap - EXIT  # STAGE is now the live prefix; don't auto-delete it
  [[ -n "$OLD" ]] && rm -rf "$OLD"
  ok "installed code to $GWX_PREFIX"

  # Symlink binary
  mkdir -p "$GWX_BIN_DIR"
  ln -sf "$GWX_PREFIX/bin/gwx" "$GWX_BIN_DIR/gwx"
  ok "linked $GWX_BIN_DIR/gwx → $GWX_PREFIX/bin/gwx"

  # PATH check
  if ! echo ":$PATH:" | grep -q ":$GWX_BIN_DIR:"; then
    warn "$GWX_BIN_DIR is not in your \$PATH"
    note "add to your shell rc: export PATH=\"$GWX_BIN_DIR:\$PATH\""
  fi

  # gws install
  echo
  if have gws; then
    ok "gws found ($(command -v gws))"
  else
    case "$WITH_GWS" in
      yes) install_gws || warn "gws install failed; proceeding" ;;
      no)  note "gws install skipped" ;;
      ask)
        if [[ "$(prompt_yn 'Install gws (Google Workspace CLI) via npm now? [Y/n]:' y)" == yes ]]; then
          install_gws || warn "gws install failed; proceeding"
        else
          warn "gws not installed — install later with:"
          note "  npm install -g @googleworkspace/cli"
        fi
        ;;
    esac
  fi

  # Pin gws absolute path so the wrapper isn't fooled by a hostile $PATH at
  # call time (see security note in bin/gwx:resolve_gws_bin).
  #
  # `command -v gws` on fnm/asdf/nvm-managed systems returns a per-shell
  # symlink (e.g. ~/.local/state/fnm_multishells/<shell-id>/bin/gws) that
  # only resolves inside the original fnm shell. When agents launch in a
  # fresh shell that path is broken — we'd report "gws not installed" when
  # it actually is. Resolve to the stable real path before pinning.
  if have gws; then
    mkdir -p "$GWX_CONFIG_DIR"
    chmod 700 "$GWX_CONFIG_DIR" 2>/dev/null || true
    local gws_pin
    gws_pin="$(command -v gws)"
    if command -v realpath >/dev/null 2>&1; then
      gws_pin="$(realpath "$gws_pin" 2>/dev/null || command -v gws)"
    fi
    # Sanity check: must still be executable. Otherwise fall back to
    # `command -v` and accept the per-shell pin as a last resort.
    [[ -x "$gws_pin" ]] || gws_pin="$(command -v gws)"
    printf '%s\n' "$gws_pin" > "$GWX_CONFIG_DIR/gws_bin"
    chmod 600 "$GWX_CONFIG_DIR/gws_bin"
    ok "pinned gws path: $gws_pin"

    # Clear the cached keyring-backend probe result. The pref records what
    # the *previous* gws binary's codesign supported; a reinstall may have
    # swapped the binary (different version, different arch, different
    # signing), so the next login should re-probe rather than trust the
    # stale answer. Per-account overrides are preserved.
    if [[ -f "$GWX_CONFIG_DIR/keyring_backend" ]]; then
      rm -f "$GWX_CONFIG_DIR/keyring_backend"
      note "cleared cached keyring-backend probe (will re-probe on next login)"
    fi
  fi

  # Permission deny
  echo
  case "$WITH_PERMISSION_DENY" in
    yes) add_permission_deny || true ;;
    no)  note "permission deny skipped" ;;
    ask)
      if [[ "$(prompt_yn 'Block raw \`gws\` calls in Claude Code (recommended)? [Y/n]:' y)" == yes ]]; then
        add_permission_deny || true
      fi
      ;;
  esac

  echo
  if [[ -f "$GWX_CONFIG_DIR/accounts.list" ]]; then
    ok "config preserved at $GWX_CONFIG_DIR"
  else
    note "no config yet — run 'gwx init' to set up your accounts"
  fi

  echo
  ok "${VERB} complete."
  echo
  # Compute padding so the '#' comments align regardless of GWX_PREFIX length.
  local nx_cmd1="gwx init"
  local nx_cmd2="cd /path/to/your/agent && gwx skills install"
  local nx_cmd3="claude --plugin-dir $GWX_PREFIX"
  local nx_w=${#nx_cmd1}; (( ${#nx_cmd2} > nx_w )) && nx_w=${#nx_cmd2}; (( ${#nx_cmd3} > nx_w )) && nx_w=${#nx_cmd3}
  echo "Next steps:"
  printf "  %-${nx_w}s  # %s\n" "$nx_cmd1" "set up OAuth + accounts"
  printf "  %-${nx_w}s  # %s\n" "$nx_cmd2" "install rewritten gws skills there"
  printf "  %-${nx_w}s  # %s\n" "$nx_cmd3" "load gwx plugin per session"
  echo
  echo "Or alias for convenience:"
  echo "  alias claude-gwx='claude --plugin-dir \"$GWX_PREFIX\"'"
}

cmd_uninstall() {
  echo "gwx uninstaller"
  echo "  prefix:    $GWX_PREFIX"
  echo "  bin link:  $GWX_BIN_DIR/gwx"
  [[ "$PURGE" -eq 1 ]] && echo "  config:    $GWX_CONFIG_DIR  (will be REMOVED)"
  echo

  if [[ -L "$GWX_BIN_DIR/gwx" ]]; then
    rm "$GWX_BIN_DIR/gwx"
    ok "removed binary symlink"
  fi
  if [[ -d "$GWX_PREFIX" ]]; then
    rm -rf "$GWX_PREFIX"
    ok "removed $GWX_PREFIX"
  fi

  # Always drop the cached keyring-backend probe and pinned gws path even
  # without --purge: both are install-state (pointer + probe result for
  # the gws binary at install time), not user data. Leaving them behind
  # would mislead a future fresh install.
  if [[ -f "$GWX_CONFIG_DIR/keyring_backend" ]]; then
    rm -f "$GWX_CONFIG_DIR/keyring_backend"
    ok "cleared cached keyring-backend probe"
  fi
  if [[ -f "$GWX_CONFIG_DIR/gws_bin" ]]; then
    rm -f "$GWX_CONFIG_DIR/gws_bin"
    ok "cleared pinned gws path"
  fi

  if [[ "$PURGE" -eq 1 ]]; then
    if [[ -d "$GWX_CONFIG_DIR" ]]; then
      # --purge alone (interactive TTY) prompts for "yes" confirmation.
      # --purge with --non-interactive (or no TTY) is treated as confirmation —
      # the user passed both flags; that IS the explicit consent. Previously
      # this combination silently skipped the purge and exited 0, which made
      # users (and CI scripts) think their data had been wiped when it hadn't.
      if [[ "$NON_INTERACTIVE" -eq 1 || ! -t 0 ]]; then
        rm -rf "$GWX_CONFIG_DIR"
        ok "deleted $GWX_CONFIG_DIR (--purge + non-interactive = consent)"
      else
        warn "about to delete $GWX_CONFIG_DIR (accounts and credentials)"
        read -rp "type 'yes' to confirm: " confirm
        if [[ "$confirm" == "yes" ]]; then
          rm -rf "$GWX_CONFIG_DIR"
          ok "deleted $GWX_CONFIG_DIR"
        else
          note "skipped"
        fi
      fi
    fi
    if [[ -d "$HOME/.cache/gwx" ]]; then
      rm -rf "$HOME/.cache/gwx"
      ok "deleted $HOME/.cache/gwx"
    fi
  else
    [[ -d "$GWX_CONFIG_DIR" ]] && note "config preserved at $GWX_CONFIG_DIR (use --purge to remove)"
  fi

  echo
  ok "uninstall complete."
}

case "$VERB" in
  install|update) cmd_install ;;
  uninstall)      cmd_uninstall ;;
esac
