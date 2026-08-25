# Dependencies — Ka0s Multi Meters

What you need installed to build, run, test or release this addon. Commands are for
**WSL2 / Ubuntu** (the collection's development environment). How to *verify* the addon once you are
set up is `docs/testing.md`; this file only covers *what to install*.

Every entry says what needs it and how that is known. Anything only plausibly required is marked as
such rather than listed as a requirement.

## Runtime (in-game) — what a player needs

- **World of Warcraft (Retail), patch 12.0 or later.** Single `## Interface: 120007` line in
  `MultiMeters.toc` — Retail only.

  The version floor is a real requirement, not the usual boilerplate: this addon reads
  `C_DamageMeter`, which does not exist before 12.0. On an older client
  `NS.Compat.IsDamageMeterAvailable()` returns false and the window renders its "meter unavailable"
  prompt instead of rows — it degrades rather than erroring, but it shows nothing useful.

- **Blizzard's built-in damage meter, enabled.** Evidence:
  `C_DamageMeter.IsDamageMeterAvailable()` at `core/Compat.lua`, consumed by
  `modules/Provider.lua`. Every statistic comes from it; this addon does not read the combat log.
  When it is unavailable the addon surfaces Blizzard's own `failureReason` in the window.

- **Nothing else.** Every library is vendored under `libs/` and committed (library-stack), so the
  player installs no separate library addon. `## OptionalDeps:` names the vendored libs for load
  ordering, not as things to download.

## Development — the contributor toolchain

| Tool | Version | Needed for | Evidence |
|---|---|---|---|
| `lua5.1` (+ `luac`) | **5.1 exactly** | the headless suite, `lua tests/run.lua` | `tests/_kit/loader.lua` uses `setfenv` |
| `luacheck` | any recent | `luacheck .`, the other half of the green gate | `.luacheckrc` at the repo root |
| `lizard` | any recent | the `complexity` suite of `tests/_kit/run-automated-tests.sh` | `tests/_kit/run-automated-tests.sh` invokes `lizard` |
| `git` | any recent | vendoring, `diff -r` against the LibKa0s repo, and the runner's own provenance stamp | library-stack-§7; `tests/_kit/run-automated-tests.sh` calls `git describe` / `git rev-parse` / `git status --porcelain` |
| `bash` | **4.x or later** | `tests/_kit/run-automated-tests.sh` — the whole automated-test bundle | its shebang is `#!/usr/bin/env bash`, and line 142 declares an associative array (`declare -A ST DUR NOTE`), which `dash`/POSIX `sh` has no syntax for |

**Lua 5.1 is a requirement, not a preference.** The harness sandboxes each source file with
`setfenv`, which was removed in 5.2 — "5.2 will probably work" is false and costs an hour to
disprove.

**`bash` is a requirement too, for the same kind of reason.** The runner keeps its four suites'
status, duration and note in associative arrays; running it under `sh` fails at `declare -A` before
a single suite starts. `lua tests/run.lua` and `luacheck .` — the green commit gate — need no shell
beyond the one you typed them into.

```sh
# Lua 5.1 and luacheck
sudo apt-get update
sudo apt-get install -y lua5.1 luarocks
sudo luarocks install luacheck

# lizard — via pipx, NOT pip. Ubuntu 24.04 marks its Python EXTERNALLY-MANAGED (PEP 668),
# so `pip install lizard` fails; pipx installs it into its own venv and puts it on PATH.
sudo apt-get install -y pipx
pipx ensurepath          # then open a new shell, or: source ~/.bashrc
pipx install lizard

# verify — each of these must print a version
lua5.1 -v                # Lua 5.1.5 …   (if `lua` is not 5.1, use lua5.1 explicitly)
luacheck --version
lizard --version
git --version
bash --version         # GNU bash, version 4.x or 5.x — Ubuntu ships one by default
```

Versions are pinned only where a version matters: `lua5.1` is hard, `luacheck` and `lizard` are
"any recent" and pinning them would be false precision.

## Release / assets

**Nothing.** There is no packaging step here that needs a tool, and no asset in this repo is
generated at build time.

The header-control icons and the monospace face used to need a graphics stack -- Python, Pillow,
numpy and `gh`, for `tools/artwork/icon_cleaner.py`. **Both the art and the tool moved into LibKa0s**
(v1.9.1, `LibKa0s-Media-1.0`), so this addon carries them as part of the vendored payload and
regenerating them is that repo's job and that repo's toolchain -- see
[LibKa0s' own DEPENDENCIES.md](https://github.com/tusharsaxena/LibKa0s/blob/master/DEPENDENCIES.md).
Nothing here reads a PNG or writes a TGA any more.

The one asset still in this repo, `media/textures/Default.tga`, is committed and unused (issue #4).

## Am I set up correctly?

```sh
lua tests/run.lua                                     # the suite — must be green
luacheck .                                            # must be 0 warnings / 0 errors
lizard -l lua -x "./libs/*" -x "./tests/_kit/*" .     # the complexity report (release-time)
```

See `docs/testing.md` for what those commands mean and when each is run.
