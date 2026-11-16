# reslv

`nix run github:Viruliant/reslv` resolves `{{{path:...}}}` and `{{{var_str:...}}}` tags:

- Finds `sws/sws.json` (lists `./coconuts/TestA.md`)
- Reads `sws/coconuts/TestA.md.sws` → contains `{{{path:"./TestB.md"}}}`
- Recurses into `sws/coconuts/TestB.md` → contains `{{{path:"./TestC.md"}}}`
- Recurses into `sws/coconuts/TestC.md` → contains `{{{var_str:"some_str"}}}`
- Writes the fully resolved content back to `sws/coconuts/TestA.md`

## Commands

`nix run github:Viruliant/reslv` will "just work"

```bash
# checkout and run with
git clone https://github.com/Viruliant/reslv.git ~/reslv
cd ~/reslv
# requirements.bak.txt (repo root) is the only editable source
# regenerates nix/requirements.txt, nix/pyproject.toml, nix/uv.lock from it
./nix/update-lock.sh
nix run
```

## How it works

`nix build` produces the `reslv` binary. Running it:

1. Auto-discovers `sws/sws.json` from cwd upward
2. For each file in the `"files"` list, looks for `<file>.sws`
3. Resolves `{{{path:"..."}}}` tags by recursively reading referenced files
4. Resolves `{{{var_str:"name"}}}` tags from `--var NAME=VALUE` arguments
5. Writes resolved output back to the original file

## Gotchas

- `package.nix` pins the pyproject-nix / uv2nix / build-system-pkgs git revs:
  un-pinned `fetchGit` is an "unlocked" input and fails in pure evaluation
  mode (`nix build`, `nix develop`). Bump revs deliberately.
- `package.nix` `projectName = "reslv"` must match `pyproject.toml`
  `[project] name`, which `update-lock.sh` hardcodes.
- The namespaced venv lives at `bin/reslv-env/` (not `bin/reslv/`)
  so it can't collide with the `reslv` launcher.

## Edit Python env

Edit `requirements.bak.txt`, then regenerate:

```bash
# 1. Edit requirements.bak.txt (add/remove deps)
echo "requests" >> requirements.bak.txt

# 2. Regenerate lock files (needs network)
./nix/update-lock.sh

# 3. Rebuild
nix build

# 4. Run
nix run
```
