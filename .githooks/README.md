# Git hooks (`.githooks/`)

These hooks are **not** installed by cloning the repository. Git only reads
`core.hooksPath`, so every contributor opts in once:

```bash
# from the repository root
git config core.hooksPath .githooks
```

`scripts/install-hooks.ps1` does exactly that (and `scripts/install-hooks.sh` is
the bash equivalent):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-hooks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-hooks.ps1 -Uninstall
```

## Why `core.hooksPath` instead of copying into `.git/hooks`

* The hooks are versioned. A fix to `verify-repo` reaches everyone on `git pull`
  instead of requiring a re-install.
* Nothing has to be made executable in the working tree. `git config` is stored
  in `.git/config`, which is per-clone and never committed, so the hooks are
  "executable-bit agnostic" by construction.
* `git lfs install` writes its own hooks into `.git/hooks`. Keeping ours in
  `.githooks/` means the two never overwrite each other. (This repository stores
  no LFS objects, so the LFS pre-push hook is not needed.)

Git for Windows runs hooks through its bundled `bash`, and the hooks here are
plain POSIX `sh`/`bash`. `pre-commit` prefers the PowerShell gate on Windows and
transparently falls back to `scripts/verify-repo.sh` elsewhere.

## The hooks

| Hook | What it does | Bypass |
| --- | --- | --- |
| `pre-commit` | Runs `scripts/verify-repo.ps1 -StagedOnly` (or `verify-repo.sh --staged-only`) and rejects the commit if the staged delta contains a forbidden artifact, a credential-looking string, or a `third_party/` file that is not a submodule gitlink. | `git commit --no-verify` |
| `commit-msg` | Enforces Conventional Commits; allows `Merge`/`Revert`/`fixup!`/`squash!` through. | `git commit --no-verify` |

CI runs the same gate against the **whole index**, so `--no-verify` only defers
the failure to the PR. That is deliberate: the gate is a convenience locally and
a hard requirement in CI.

## Adding a hook

1. Add an executable-agnostic bash script named exactly like the Git hook
   (`post-merge`, `pre-push`, …).
2. Keep it dependency-free: `git` plus coreutils, nothing else. A hook that
   needs Node or PowerShell must degrade gracefully when they are missing.
3. Document it in the table above and in `docs/design/ci.md`.
