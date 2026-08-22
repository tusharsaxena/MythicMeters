# Dependencies — Ka0s Mythic Meters

What you need installed to build, run, test or release this addon. Commands are for
**WSL2 / Ubuntu** (the collection's development environment). How to *verify* the addon once you are
set up is `docs/testing.md`; this file only covers *what to install*.

Every entry says what needs it and how that is known. Anything only plausibly required is marked as
such rather than listed as a requirement.

## Runtime (in-game) — what a player needs

- **World of Warcraft (Retail), patch 12.0 or later.** Single `## Interface: 120007` line in
  `MythicMeters.toc` — Retail only.

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
| `git` | any recent | vendoring, and `diff -r` against the LibKa0s repo | library-stack-§7 |
| POSIX shell | any | the commands in this file and in `docs/testing.md` | `tests/_kit/run-automated-tests.sh` shebang |

**Lua 5.1 is a requirement, not a preference.** The harness sandboxes each source file with
`setfenv`, which was removed in 5.2 — "5.2 will probably work" is false and costs an hour to
disprove.

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
```

Versions are pinned only where a version matters: `lua5.1` is hard, `luacheck` and `lizard` are
"any recent" and pinning them would be false precision.

## Release / assets

Needed only to REGENERATE the header-control icons. Nothing here is required to run the addon, run
its tests, or ship it -- the TGAs are committed, and `tools/artwork/icon_cleaner.py` exists so the
art can be rebuilt at another size or replaced from another source without guessing at where the
current ones came from.

| Tool | Version | Used by | Evidence |
|---|---|---|---|
| `python3` | 3.8+ | `tools/artwork/icon_cleaner.py` | the script's shebang |
| `Pillow` | any recent | reading the source PNGs and writing 32-bit TGA | `from PIL import Image` |
| `numpy` | any recent | the solidify and normalize stages | `import numpy as np` |
| `gh` | any recent | fetching the sources from `iconic/open-iconic` | `_gh_file()` shells out to it |

```bash
sudo apt-get install -y python3 pipx
# Pillow and numpy via the distro, which is what Ubuntu 24.04's PEP 668 marker
# wants -- `pip install` into the system Python fails with EXTERNALLY-MANAGED.
sudo apt-get install -y python3-pil python3-numpy
```

Verify: `python3 -c "import PIL, numpy; print('ok')"` prints `ok`, and `gh auth status` reports a
logged-in account.

## Am I set up correctly?

```sh
lua tests/run.lua                                     # the suite — must be green
luacheck .                                            # must be 0 warnings / 0 errors
lizard -l lua -x "./libs/*" -x "./tests/_kit/*" .     # the complexity report (release-time)
```

See `docs/testing.md` for what those commands mean and when each is run.
