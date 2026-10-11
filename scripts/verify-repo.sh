#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Repository hygiene gate for HarmonyBridge -- bash twin of verify-repo.ps1.
#
# Why two implementations? The project is authored on Windows (so the PowerShell
# version is authoritative and is what the pre-commit hook and CI call), but a
# contributor on Linux/macOS, or a Ubuntu CI runner, should not need PowerShell
# to run the same gate. Both scripts read scripts/forbidden-patterns.txt, so the
# rules cannot drift; the checks and the exit codes are identical.
#
# Usage:
#   scripts/verify-repo.sh                # whole index (CI / pre-push)
#   scripts/verify-repo.sh --staged-only  # staged delta only (pre-commit)
#   scripts/verify-repo.sh --json
#   scripts/verify-repo.sh --patterns <file> --max-line-length <n>
#
# Exit codes: 0 = clean, 1 = violations found, 2 = the check could not run.
# ---------------------------------------------------------------------------
set -u

REPO_ROOT=""
STAGED_ONLY=0
JSON=0
PATTERNS_FILE=""
MAX_LINE_LENGTH=300

while [ $# -gt 0 ]; do
    case "$1" in
        --staged-only) STAGED_ONLY=1 ;;
        --json) JSON=1 ;;
        --patterns) shift; PATTERNS_FILE="${1:-}" ;;
        --patterns=*) PATTERNS_FILE="${1#--patterns=}" ;;
        --max-line-length) shift; MAX_LINE_LENGTH="${1:-300}" ;;
        --max-line-length=*) MAX_LINE_LENGTH="${1#--max-line-length=}" ;;
        --repo-root) shift; REPO_ROOT="${1:-}" ;;
        --repo-root=*) REPO_ROOT="${1#--repo-root=}" ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *)
            printf 'verify-repo.sh: unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

if [ -z "$REPO_ROOT" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "$script_dir/.." && pwd)"
fi

if [ -z "$PATTERNS_FILE" ]; then
    PATTERNS_FILE="$REPO_ROOT/scripts/forbidden-patterns.txt"
fi

if ! command -v git >/dev/null 2>&1; then
    printf 'verify-repo: git not found on PATH; cannot inspect the repository.\n' >&2
    exit 2
fi

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'verify-repo: %s is not a git work tree.\n' "$REPO_ROOT" >&2
    exit 2
fi

if [ ! -f "$PATTERNS_FILE" ]; then
    printf 'verify-repo: pattern file not found: %s\n' "$PATTERNS_FILE" >&2
    exit 2
fi

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t verifyrepo)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

ARTIFACTS="$TMP_DIR/artifacts.txt"
SECRETS="$TMP_DIR/secrets.txt"
: > "$ARTIFACTS"
: > "$SECRETS"

# --- parse the shared pattern file ----------------------------------------
section=""
while IFS= read -r raw || [ -n "$raw" ]; do
    line="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in
        \#*) continue ;;
    esac
    case "$line" in
        \[*\])
            section="$(printf '%s' "$line" | tr -d '[]' | tr '[:upper:]' '[:lower:]')"
            continue
            ;;
    esac
    case "$section" in
        artifacts) printf '%s\n' "$line" >> "$ARTIFACTS" ;;
        secrets)   printf '%s\n' "$line" >> "$SECRETS" ;;
    esac
done < "$PATTERNS_FILE"

# --- enumerate the index ---------------------------------------------------
# Format: "<mode> <object> <stage>\t<path>"
git -C "$REPO_ROOT" ls-files -s > "$TMP_DIR/index-s.txt" 2>/dev/null || {
    printf 'verify-repo: `git ls-files -s` failed.\n' >&2
    exit 2
}

# path -> mode, and the two derived sets.
awk -F'\t' '{ split($1, a, " "); print a[1] "\t" $2 }' "$TMP_DIR/index-s.txt" > "$TMP_DIR/index-modes.txt"

: > "$TMP_DIR/all-regular.txt"
: > "$TMP_DIR/all-gitlinks.txt"
while IFS="$(printf '\t')" read -r mode path; do
    [ -z "$path" ] && continue
    if [ "$mode" = "160000" ]; then
        printf '%s\n' "$path" >> "$TMP_DIR/all-gitlinks.txt"
    else
        printf '%s\n' "$path" >> "$TMP_DIR/all-regular.txt"
    fi
done < "$TMP_DIR/index-modes.txt"

if [ "$STAGED_ONLY" -eq 1 ]; then
    git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR > "$TMP_DIR/staged.txt" 2>/dev/null || : > "$TMP_DIR/staged.txt"
    if [ -s "$TMP_DIR/staged.txt" ]; then
        # Keep only index entries whose path is in the staged delta.
        grep -F -x -f "$TMP_DIR/staged.txt" "$TMP_DIR/all-regular.txt" > "$TMP_DIR/tracked.txt" 2>/dev/null || : > "$TMP_DIR/tracked.txt"
        grep -F -x -f "$TMP_DIR/staged.txt" "$TMP_DIR/all-gitlinks.txt" > "$TMP_DIR/gitlinks.txt" 2>/dev/null || : > "$TMP_DIR/gitlinks.txt"
    else
        # Nothing staged (e.g. `git commit --amend --no-edit`): whole index.
        cp "$TMP_DIR/all-regular.txt" "$TMP_DIR/tracked.txt"
        cp "$TMP_DIR/all-gitlinks.txt" "$TMP_DIR/gitlinks.txt"
    fi
else
    cp "$TMP_DIR/all-regular.txt" "$TMP_DIR/tracked.txt"
    cp "$TMP_DIR/all-gitlinks.txt" "$TMP_DIR/gitlinks.txt"
fi

TRACKED_COUNT="$(wc -l < "$TMP_DIR/tracked.txt" | tr -d ' ')"
GITLINK_COUNT="$(wc -l < "$TMP_DIR/gitlinks.txt" | tr -d ' ')"

FINDINGS="$TMP_DIR/findings.txt"
: > "$FINDINGS"

add_finding() {
    # rule \t path \t detail
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FINDINGS"
}

# --- Rule A: forbidden artifacts ------------------------------------------
# Patterns are gitignore-flavoured globs: a leading `/` anchors at the repo
# root, everything else matches at any depth. Translate to an ERE over the
# repo-relative POSIX path.
while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    anchored=0
    case "$pattern" in
        /*) anchored=1; pattern="${pattern#/}" ;;
    esac
    # escape ERE metacharacters except * and ?
    esc="$(printf '%s' "$pattern" | sed -e 's/[][\.^$+{}()|]/\\&/g')"
    esc="$(printf '%s' "$esc" | sed -e 's/\*/[^\/]*/g' -e 's/?/[^\/]/g')"
    if [ "$anchored" -eq 1 ]; then
        regex="^${esc}$"
    else
        regex="(^|/)${esc}$"
    fi
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        if printf '%s\n' "$path" | grep -E -q "$regex"; then
            add_finding "forbidden-artifact" "$path" "matched \`$pattern\`"
        fi
    done < "$TMP_DIR/tracked.txt"
done < "$ARTIFACTS"

# --- Rule B: third_party/ must be submodule gitlinks only ------------------
if [ -f "$REPO_ROOT/.gitmodules" ]; then
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        case "$path" in
            third_party|third_party/*)
                add_finding "third-party-not-submodule" "$path" \
                    "third_party/ may only contain submodule gitlinks; a vendored file here breaks the licensing boundary"
                ;;
        esac
    done < "$TMP_DIR/tracked.txt"
fi

# --- Rule C: .gitmodules integrity ---------------------------------------
if [ -f "$REPO_ROOT/.gitmodules" ]; then
    declared_count=0
    while IFS= read -r declared || [ -n "$declared" ]; do
        declared="$(printf '%s' "$declared" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$declared" ] && continue
        declared_count=$((declared_count + 1))
        if ! grep -F -x -q "$declared" "$TMP_DIR/all-regular.txt" 2>/dev/null && \
           ! grep -F -x -q "$declared" "$TMP_DIR/all-gitlinks.txt" 2>/dev/null; then
            add_finding "gitmodules-missing-from-index" "$declared" \
                ".gitmodules declares this path but the index has no entry; a fresh clone would miss it"
        elif ! grep -F -x -q "$declared" "$TMP_DIR/all-gitlinks.txt" 2>/dev/null; then
            add_finding "submodule-not-a-gitlink" "$declared" \
                ".gitmodules declares a submodule but the index entry is a regular file, not mode 160000"
        fi
    done < <(grep -E '^[[:space:]]*path[[:space:]]*=' "$REPO_ROOT/.gitmodules" | sed -E 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//')
    if [ "$declared_count" -eq 0 ]; then
        add_finding "gitmodules-empty" ".gitmodules" "no [submodule \"name\"] path = ... entries found"
    fi
fi

# --- Rule D: secret-looking strings in tracked text files -----------------
# `git grep --cached -I` reads the index (what would be committed), skips
# binaries, and gets explicit pathspecs so --staged-only really means staged.
SECRET_SCAN_SKIPPED=0
if [ "$TRACKED_COUNT" -eq 0 ]; then
    SECRET_SCAN_SKIPPED=1
else
    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        hits="$(git -C "$REPO_ROOT" grep --cached -E -I -n --no-color -e "$pattern" -- $(cat "$TMP_DIR/tracked.txt") 2>"$TMP_DIR/grep.err")"
        status=$?
        if [ "$status" -gt 1 ]; then
            SECRET_SCAN_SKIPPED=1
            printf 'verify-repo: secret scan for `%s` failed (git grep exit %s)\n' "$pattern" "$status" >&2
            continue
        fi
        [ -z "$hits" ] && continue
        while IFS= read -r hit; do
            [ -z "$hit" ] && continue
            path="${hit%%:*}"
            rest="${hit#*:}"
            lineno="${rest%%:*}"
            content="${rest#*:}"
            if [ "${#content}" -gt "$MAX_LINE_LENGTH" ]; then continue; fi
            add_finding "possible-secret" "$path" \
                "line $lineno matches \`$pattern\` -- remove the credential and rotate it"
        done <<< "$hits"
    done < "$SECRETS"
fi

# --- report ----------------------------------------------------------------
FINDING_COUNT="$(wc -l < "$FINDINGS" | tr -d ' ')"
[ -z "$FINDING_COUNT" ] && FINDING_COUNT=0

if [ "$STAGED_ONLY" -eq 1 ]; then MODE="staged changes only"; else MODE="tracked files (whole index)"; fi

if [ "$JSON" -eq 1 ]; then
    printf '{\n'
    printf '  "repoRoot": %s,\n' "$(printf '%s' "$REPO_ROOT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
    printf '  "mode": "%s",\n' "$MODE"
    printf '  "filesChecked": %s,\n' "$TRACKED_COUNT"
    printf '  "gitlinks": %s,\n' "$GITLINK_COUNT"
    printf '  "findingsCount": %s,\n' "$FINDING_COUNT"
    printf '  "findings": [\n'
    first=1
    while IFS="$(printf '\t')" read -r rule path detail; do
        [ -z "$rule" ] && continue
        [ "$first" -eq 0 ] && printf ',\n'
        first=0
        d_esc="$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        p_esc="$(printf '%s' "$path" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf '    { "Rule": "%s", "Path": "%s", "Detail": "%s" }' "$rule" "$p_esc" "$d_esc"
    done < "$FINDINGS"
    printf '\n  ]\n}\n'
else
    printf '\n'
    printf '  verify-repo: %s\n' "$REPO_ROOT"
    printf '  scope: %s   regular files: %s   submodule gitlinks: %s\n' "$MODE" "$TRACKED_COUNT" "$GITLINK_COUNT"
    printf '  %s\n' "------------------------------------------------------------------------------"
    if [ "$FINDING_COUNT" -eq 0 ]; then
        printf '  [ OK ] no forbidden artifacts, no vendored third_party files,\n'
        printf '         no unresolved .gitmodules paths, no credential-looking strings.\n'
    else
        sed -e 's/\t/|/' "$FINDINGS" | awk -F'|' '{ print $1 }' | sort -u | while IFS= read -r rule; do
            printf '  %s (%s)\n' "$rule" "$(awk -F'\t' -v r="$rule" '$1==r' "$FINDINGS" | wc -l | tr -d ' ')"
            awk -F'\t' -v r="$rule" '$1==r { printf "    - %s\n        %s\n", $2, $3 }' "$FINDINGS"
        done
    fi
    printf '  %s\n' "------------------------------------------------------------------------------"
    if [ "$SECRET_SCAN_SKIPPED" -eq 1 ]; then
        printf '  WARNING: the secret scan could not evaluate every pattern; see above.\n'
    fi
    if [ "$FINDING_COUNT" -eq 0 ]; then
        printf '  VERDICT: PASS\n\n'
    else
        printf '  VERDICT: FAIL -- %s finding(s).\n' "$FINDING_COUNT"
        printf '  Fix them before committing. Build outputs are produced by the build, never committed:\n'
        printf '  see CONTRIBUTING.md and docs/design/ci.md.\n\n'
    fi
fi

if [ "$FINDING_COUNT" -gt 0 ]; then exit 1; fi
exit 0
