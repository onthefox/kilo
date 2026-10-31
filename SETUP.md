# Full-Setup Patterns

Repeatable, battle-tested patterns for setting up a development environment for this repository (Kilo — a Bun + Turborepo monorepo) from a fresh clone. These patterns include the Windows-specific workarounds discovered while setting up on Windows 11.

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| [Bun](https://bun.sh) | **1.3.9+** | Enforced by `packageManager: bun@1.3.9` in `package.json` |
| git | recent | For clone/commit; TLS quirks below |

Verify:

```sh
bun --version   # must be >= 1.3.9
git --version
```

## 1. Clone the fork

Fork `Kilo-Org/kilo` on GitHub first, then:

```sh
git clone https://github.com/<YOUR_USER>/kilo.git
cd kilo
```

## 2. Configure remotes

```sh
git remote add upstream https://github.com/Kilo-Org/kilo.git
git remote -v
# origin    https://github.com/<YOUR_USER>/kilo.git (fetch/push)
# upstream  https://github.com/Kilo-Org/kilo.git  (fetch only)
```

> **Note:** `Kilo-Org/kilo` is **archived**. The actively maintained successor lives at
> `Kilo-Org/kilocode`. Consider adding it as an additional remote if you need fresh upstream changes:
>
> ```sh
> git remote add kilocode https://github.com/Kilo-Org/kilocode.git
> ```

## 3. Install dependencies

```sh
bun install
```

### Windows: the same-drive cache pattern (important)

On Windows, `bun install` can fail during the final cache-rename step with:

```
error: moving "<pkg>" to cache dir failed
EPERM: Operation not permitted (NtSetInformationFile())
```

This is antivirus/Defender file-locking racing bun's rename of extracted temp dirs into the cache. Two mitigations, applied together, make installs reliable:

1. **Put the cache on the same drive as the repo** (avoids cross-device renames):

   ```powershell
   $env:BUN_INSTALL_CACHE_DIR = "<repo-parent>\.bun-cache"   # e.g. e:\dev\.bun-cache for e:\dev\kilo
   bun install
   ```

2. **Retry loop** — each retry skips already-cached packages, so progress is incremental and the install converges even if a few packages EPERM per run:

   ```powershell
   for ($i = 0; $i -lt 5; $i++) {
     bun install
     if ($LASTEXITCODE -eq 0) { break }
     # clear stuck temp dirs (dot-prefixed) left by a failed rename
     Get-ChildItem $env:BUN_INSTALL_CACHE_DIR -Directory -Filter '.*' |
       Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
   }
   ```

3. *(Optional, needs admin)* Add a Defender exclusion for the cache dir to eliminate the race entirely:

   ```powershell
   Add-MpPreference -ExclusionPath "<repo-parent>\.bun-cache"
   ```

`scripts/setup.ps1` in this repo implements all of the above automatically.

> If bun appears to **hang** (zero CPU for minutes, no output) after an EPERM, kill it
> (`Stop-Process -Name bun -Force`) and re-run the retry loop — the hang is a side effect
> of the failed rename, not a working state.

## 4. Typecheck

Typecheck runs [typescript-go](https://github.com/microsoft/typescript-go) (`tsgo`) through Turborepo:

```sh
bun turbo typecheck --concurrency=1
```

### Windows: why `--concurrency=1` (tsgo OOM)

The three largest packages (`@kilocode/cli`, `@opencode-ai/app`, `@opencode-ai/desktop`) each spawn a `tsgo` process that can consume several GB of RAM. When turbo runs them **in parallel** (the default), the processes crash with:

```
fatal error: out of memory
runtime: cannot allocate memory
    github.com/microsoft/typescript-go/internal/execute/tsc.EmitFilesAndReportErrors
```

Fix — run one typecheck at a time (verified: 10/10 tasks pass). Cached tasks stay cached between runs, so a serial re-run only re-executes the packages that OOM'd.

### Windows: git symlinks break typecheck (TS1128)

This repo contains ~42 git symlinks (git file mode `120000`). On Windows, git defaults to `core.symlinks=false`, so symlinks are checked out as **plain text files whose content is the target path string**. `packages/app/src/custom-elements.d.ts` is one of them, and tsc then fails with:

```
src/custom-elements.d.ts(1,1): error TS1128: Declaration or statement expected.
```

Fix — overwrite the placeholder with the real target's content (the symlink points into `packages/ui`):

```powershell
Copy-Item 'packages/ui/src/custom-elements.d.ts' 'packages/app/src/custom-elements.d.ts' -Force
```

Only this one symlink blocks typecheck (the rest live under `public/`, fonts, images). The systemic alternative: enable Windows Developer Mode, then `git config core.symlinks true` and re-checkout.

## 5. Run

| Command | What it does |
|---------|--------------|
| `bun dev` | Run the `opencode` package from source (`--conditions=browser`) |
| `bun run dev:web` | Web dev server |
| `bun run dev:desktop` | Tauri desktop dev |

## 6. Build the standalone binary

```sh
bun ./packages/kilo-cli/script/build.ts --single
# output: packages/kilo-cli/dist/kilo-cli-<platform>/bin/kilo
```

## 7. Tests

> ⚠️ **Never run `bun test` from the repo root** — the root `test` script intentionally exits 1 to prevent this.

Run tests through Turborepo, which builds dependencies first:

```sh
bun turbo run test --filter=opencode          # core package tests
bun turbo run test --filter=@opencode-ai/app  # app package tests
```

or run a single package's tests from inside the package directory (`cd packages/<pkg> && bun test`).

## Windows Troubleshooting Patterns

Collected patterns for Windows 11 (cmd.exe default shell):

### a) `curl` exit 35 (schannel certificate revocation check failed)

Use git's schannel toggle for clones over TLS:

```sh
git -c http.schannelCheckRevoke=false clone https://github.com/<YOU>/kilo.git
```

### b) `gh` CLI TLS handshake timeouts

When `gh repo fork` or API calls hang with TLS errors, fall back to PowerShell REST with TLS 1.2:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-RestMethod -Method Post `
  -Uri "https://api.github.com/repos/Kilo-Org/kilo/forks" `
  -Headers @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = "application/vnd.github+json" }
```

### c) `gh` keyring / credential-manager timeouts

Skip the interactive auth keyring by providing the token via environment:

```powershell
$env:GH_TOKEN = "<token>"
gh auth status
```

### d) cmd.exe chained `set PATH=... && cd /d X && tool` silently no-ops

Chained environment mutation + `cd` in cmd one-liners can silently execute against the wrong directory. Reliable alternatives:

- `git -C <path> ...` for git commands
- Absolute paths for executables
- PowerShell with `Set-Location` for anything else

### e) bun EPERM cache-move failures

See §3 above — same-drive `BUN_INSTALL_CACHE_DIR` + retry loop + optional Defender exclusion.

### f) Long-running commands exceeding tool timeouts

When driving installs/builds from an automated harness with short timeouts, run the command in the background writing to a log file, then poll the log **directly** (no nested sleeps — the poll itself will be backgrounded). Check process liveness with a CPU-delta sample: if CPU is identical across two samples minutes apart, the process is hung, not working — kill and retry.

### g) turbo can't find the package manager ("Unable to find package manager binary")

Turbo shells out to `bun` by name. When bun lives outside `PATH` (e.g. a portable copy), prepend its directory first:

```powershell
$env:PATH = "<bun-dir>;" + $env:PATH
bun turbo typecheck --concurrency=1
```

### h) typescript-go OOM during parallel typecheck

See §4 — use `bun turbo typecheck --concurrency=1`. Turbo caches successful typechecks, so serial re-runs only re-execute the packages that previously OOM'd.

## Repository Conventions

From `CONTRIBUTING.md` / repo config:

- **Conventional Commits** for commit messages (`feat:`, `fix:`, `docs:`, `chore:` …)
- **No `any`** in TypeScript; prefer explicit types
- Prefer `const`; use early returns to reduce nesting
- `bunfig.toml` pins `exact = true` — dependency versions are always exact
- `trustedDependencies` includes esbuild, protobufjs, tree-sitter, tree-sitter-bash, web-tree-sitter (postinstall scripts allowed)
- `patchedDependencies` patches `@standard-community/standard-openapi@0.2.9` and `ghostty-web@0.3.0` — don't bump these past the patch range
- Husky git hooks are installed via the root `prepare` script (runs automatically on `bun install`)
- Turborepo: `build` depends on `^build` (deps build first); test tasks also depend on `^build`; `CI` and `KILO_DISABLE_SHARE` are global env hashes

## One-command setup (Windows PowerShell)

```powershell
.\scripts\setup.ps1 -RepoRoot . -ForkUrl "https://github.com/<YOU>/kilo.git"
```

This validates Bun ≥ 1.3.9, configures the same-drive cache, ensures remotes, runs the install retry loop, and finishes with a typecheck.