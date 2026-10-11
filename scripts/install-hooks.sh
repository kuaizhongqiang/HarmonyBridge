#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install (or uninstall) the HarmonyBridge git hooks -- bash twin of
# scripts/install-hooks.ps1. Points core.hooksPath at the versioned .githooks/
# directory, which is the whole installation: nothing is copied into .git/hooks
# and no file needs the executable bit.
#
# Usage:
#   scripts/install-hooks.sh
#   scripts/install-hooks.sh --status
#   scripts/install-hooks.sh --uninstall
#
# See .githooks/README.md.
# ---------------------------------------------------------------------------
set -u

HOOK_PATH=".githooks"
SAVED_KEY="harmonybridge.savedHooksPath"

mode="install"
for arg in "$@"; do
    case "$arg" in
        --uninstall) mode="uninstall" ;;
        --status) mode="status" ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *)
            printf 'install-hooks.sh: unknown argument: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

if ! command -v git >/dev/null 2>&1; then
    printf 'install-hooks: git not found on PATH.\n' >&2
    exit 2
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$repo_root" ]; then
    printf 'install-hooks: not inside a git work tree.\n' >&2
    exit 2
fi
cd "$repo_root" || exit 2

current="$(git config --local --get core.hooksPath 2>/dev/null || true)"
saved="$(git config --local --get "$SAVED_KEY" 2>/dev/null || true)"

case "$mode" in
    status)
        printf '\n  repo:            %s\n' "$repo_root"
        printf '  core.hooksPath:  %s\n' "${current:-(unset -> .git/hooks)}"
        printf '  saved previous:  %s\n\n' "${saved:-(none)}"
        exit 0
        ;;
    uninstall)
        if [ -z "$current" ]; then
            printf 'install-hooks: core.hooksPath is already unset; nothing to do.\n'
            exit 0
        fi
        if [ -z "$saved" ]; then
            git config --local --unset core.hooksPath
            printf 'install-hooks: core.hooksPath removed (Git now uses .git/hooks).\n'
        else
            git config --local core.hooksPath "$saved"
            printf 'install-hooks: core.hooksPath restored to %s\n' "$saved"
        fi
        git config --local --unset "$SAVED_KEY" 2>/dev/null || true
        exit 0
        ;;
esac

if [ ! -d "$HOOK_PATH" ]; then
    printf 'install-hooks: %s does not exist.\n' "$repo_root/$HOOK_PATH" >&2
    exit 2
fi

missing=""
for hook in pre-commit commit-msg; do
    [ -f "$HOOK_PATH/$hook" ] || missing="$missing $hook"
done
[ -n "$missing" ] && printf 'install-hooks: missing hook file(s):%s\n' "$missing" >&2

if [ -z "$saved" ] && [ -n "$current" ] && [ "$current" != "$HOOK_PATH" ]; then
    git config --local "$SAVED_KEY" "$current"
    printf 'install-hooks: saved the previous core.hooksPath (%s) for --uninstall.\n' "$current"
fi

if [ "$current" = "$HOOK_PATH" ]; then
    printf 'install-hooks: already installed (core.hooksPath = %s).\n' "$HOOK_PATH"
else
    git config --local core.hooksPath "$HOOK_PATH" || {
        printf 'install-hooks: failed to write core.hooksPath into .git/config.\n' >&2
        exit 1
    }
    printf 'install-hooks: core.hooksPath = %s\n' "$HOOK_PATH"
fi

# --- self-test: the hook must be runnable and behave as documented ----------
printf '\n  Verifying the hooks are wired up:\n'
probe_file="$(mktemp 2>/dev/null || mktemp -t hb-commit-msg)"
cleanup_probe() { rm -f "$probe_file"; }
trap cleanup_probe EXIT

run_commit_msg() {
    printf '%s' "$1" > "$probe_file"
    bash "$HOOK_PATH/commit-msg" "$probe_file" >/dev/null 2>&1
    return $?
}

if run_commit_msg 'not a conventional commit'; then
    printf '    [WARN] commit-msg accepted a non-conventional message\n'
else
    printf '    [ OK ] commit-msg rejects a non-conventional message\n'
fi

if run_commit_msg 'feat(hooks): wire up the conventional commit check'; then
    printf '    [ OK ] commit-msg accepts a conventional message\n'
else
    printf '    [WARN] commit-msg rejected a valid message\n'
fi

if [ "$(git config --local --get core.hooksPath 2>/dev/null || true)" = "$HOOK_PATH" ]; then
    printf '    [ OK ] git resolves hooks to %s\n' "$HOOK_PATH"
else
    printf '    [WARN] core.hooksPath does not point at %s\n' "$HOOK_PATH"
fi

printf '\n  Done. `git commit` now runs %s/pre-commit and %s/commit-msg.\n' "$HOOK_PATH" "$HOOK_PATH"
printf '  Bypass once with `git commit --no-verify` (CI runs the same gate anyway).\n\n'
exit 0
