# How someProject Compiles and Provides the Python Environment

This document explains the build pipeline that converts `requirements.bak.txt` into a fully locked, reproducible Python environment using Nix + uv2nix.

## Overview

The project uses **uv2nix**, a tool from the pyproject-nix ecosystem, to transform a `uv.lock` file (generated from `requirements.bak.txt`) into a Nix package that provides a complete Python virtual environment. The build produces:

1. A namespaced Python environment at `result/bin/someProject-env/`
2. An executed HTML report from `script.py`
3. A launcher binary `someProject` that opens the report

## Key Files

| File | Purpose |
|------|---------|
| `flake.nix` | Project entry point; defines `flake-parts` outputs |
| `package.nix` | Main derivation that builds the Python env and artifacts |
| `nix/requirements.bak.txt` | **Editable source** for user dependencies |
| `nix/requirements.txt` | Generated: resolved dependencies from `uv pip compile` |
| `nix/pyproject.toml` | Generated: TOML metadata for uv2nix |
| `nix/uv.lock` | Generated: fully pinned dependency versions |
| `nix/update-lock.sh` | Script to regenerate lockfile from `requirements.bak.txt` |
| `nix/myCustomOverrides.nix` | Hook for forcing nixpkgs-built packages (torch, etc.) |

## The Build Pipeline

### Step 1: Dependency Resolution (Manual/CI)

The pipeline starts with `requirements.bak.txt`, which the user edits:

```bash
# regenerates nix/requirements.txt, nix/pyproject.toml, nix/uv.lock from requirements.bak.txt
./nix/update-lock.sh
```

`update-lock.sh` performs three operations:

1. **`uv pip compile`**: Resolves `requirements.bak.txt` to a fully pinned `requirements.txt`
   ```bash
   uv pip compile ../requirements.bak.txt -o requirements.txt --upgrade --prerelease=allow
   ```

2. **`gen_toml`**: Creates `pyproject.toml` with the dependency list and configures PyTorch CPU index:
   ```toml
   [project]
   name = "someProject"
   version = "0.1.0"
   requires-python = ">=3.12"
   dependencies = ["numpy==1.26.4", "p2j==1.3.2", ...]
   
   [tool.uv.sources]
   torch = { index = "pytorch-cpu" }
   ```

3. **`uv lock`**: Generates `uv.lock` with hashes and exact versions for every dependency

This step requires network access to fetch PyPI metadata and wheels.

### Step 2: Nix Evaluation (flake.nix → package.nix)

When you run `nix build`, Nix evaluates `flake.nix`:

```nix
{
  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      perSystem = { system, pkgs, ... }:
        let
          pkg = pkgs.callPackage ./package.nix { };
        in {
          packages.default = pkg;
          devShells.default = pkgs.mkShell {
            packages = [ pkg ];
            inputsFrom = [ pkg ];  # pulls venv into shell
          };
        };
    }
}
```

`flake.nix` is minimal—it delegates the heavy lifting to `package.nix`.

### Step 3: uv2nix Integration (package.nix)

`package.nix` imports three pinned Git repositories from pyproject-nix:

```nix
pyproject-nix = import (builtins.fetchGit {
  url = "https://github.com/pyproject-nix/pyproject.nix.git";
  rev = "ddc400a6883b042646d0940e65971bb7f7e96107";
}) { inherit lib; };

uv2nix = import (builtins.fetchGit {
  url = "https://github.com/pyproject-nix/uv2nix.git";
  rev = "a541fda20d6784d88789cfcb221638b7c25a23dd";
}) { inherit pyproject-nix lib; };

pyproject-build-systems = import (builtins.fetchGit {
  url = "https://github.com/pyproject-nix/build-system-pkgs.git";
  rev = "953d35d03a51dbecaf3feb3fb679eb63e90ebeb4";
}) { inherit pyproject-nix uv2nix lib; };
```

**Why pinned?** Unpinned `fetchGit` fails in Nix's pure evaluation mode (used by `nix build` and `nix develop`).

#### Loading the Workspace

```nix
workspace = uv2nix.lib.workspace.loadWorkspace {
  workspaceRoot = ./nix;
};
```

This reads `nix/pyproject.toml` and `nix/uv.lock` to understand the dependency graph.

#### Creating the Overlay

```nix
uvLockedOverlay = workspace.mkPyprojectOverlay {
  sourcePreference = "wheel";  # prefer wheels over source builds
};
```

The overlay tells Nix how to fetch each package:
- If a wheel exists for the target Python version, fetch it from PyPI
- Otherwise, fall back to source builds (sdist)

#### Constructing the Python Package Set

```nix
pythonSet = (pkgs.callPackage pyproject-nix.build.packages {
  inherit python;
}).overrideScope(
  lib.composeManyExtensions [
    pyproject-build-systems.overlays.default
    uvLockedOverlay
    myCustomOverrides
  ]
);
```

The order matters:
1. **build-systems**: Provides build dependencies (meson, setuptools, etc.)
2. **uvLockedOverlay**: Adds all packages from `uv.lock`
3. **myCustomOverrides**: Allows forcing nixpkgs-built packages on top

#### Building the Virtual Environment

```nix
appPythonEnv = pythonSet.mkVirtualEnv "${projectName}-env" workspace.deps.default;
```

This creates a complete virtual environment with all locked dependencies, structured like a real venv with `bin/python3`, `bin/pip`, etc.

### Step 4: Derivation Construction (package.nix)

The final package is a `stdenv.mkDerivation`:

```nix
pkgs.stdenv.mkDerivation {
  pname = projectName;
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = [ appPythonEnv ];  # makes python3, p2j, jupyter available
  
  installPhase = ''
    export HOME=$TMPDIR

    # Convert Python script to executed notebook
    ${appPythonEnv}/bin/p2j -o -t script.ipynb script.py
    ${appPythonEnv}/bin/jupyter-nbconvert --to html --execute script.ipynb

    # Copy HTML report
    mkdir -p $out/share/${projectName}
    cp script.html $out/share/${projectName}/script.html

    # Create namespaced venv at result/bin/someProject-env/
    mkdir -p $out/bin/${projectName}-env
    for f in ${appPythonEnv}/bin/*; do
      ln -s "$f" "$out/bin/${projectName}-env/"
    done

    # Create launcher binary
    cat > $out/bin/${projectName} <<EOF
    #!${pkgs.runtimeShell}
    exec ${pkgs.xdg-utils}/bin/xdg-open $out/share/${projectName}/script.html "\$@"
    EOF
    chmod +x $out/bin/${projectName}
  '';
}
```

**Key design decisions:**
- **Namespaced venv**: Lives at `someProject-env/` to avoid colliding with system `python3`
- **Launcher**: `someProject` binary opens the HTML report via `xdg-open`
- **HOME=$TMPDIR**: Required for `p2j` and `nbconvert` to work in the sandbox

## Output Artifacts

After `nix build`, you get:

```
result/
├── bin/
│   ├── someProject              # Launcher: opens HTML report
│   └── someProject-env/         # Namespaced venv (python3, jupyter, etc.)
└── share/someProject/
    └── script.html      # Executed report
```

## Development Shell

```bash
nix develop
```

Enters a shell where `python3` is the locked venv Python, with all dependencies available. The `inputsFrom = [ pkg ]` in `flake.nix` ensures the venv packages are exposed in the shell.

## Custom Overrides

`nix/myCustomOverrides.nix` is a hook for forcing specific packages to come from nixpkgs instead of uv2nix:

```nix
{ pkgs, python }:

final: prev: {
  # Force torch from nixpkgs instead of uv.lock
  torch = pkgs.python312Packages.torch;
  
  # Or force a different Python version
  # torch = pkgs.python313Packages.torch;
}
```

This is useful for packages like `torch`, `pyside6`, or `shiboken6` that have complex build requirements or need system libraries.

## Python Version Constraint

The project uses **Python 3.12** because:

```nix
python = pkgs.python312;
```

`numpy==1.26.4` (pinned in `uv.lock`) only ships wheels up to `cp312`. On Python 3.13, uv2nix would need to build numpy from source, and numpy 1.26.4 doesn't support 3.13 at all, causing the build to fail.

## Build Options Considered

The README documents four approaches:

1. **PyPI wheels on Python 3.12** (current): Stays faithful to `uv.lock`, needs network for wheel fetches
2. **nixpkgs override**: Builds from source, works on 3.13, but version drifts from `uv.lock`
3. **Fix sdist source builds**: Provide meson-python et al., only viable for packages supporting the Python version
4. **Drop uv2nix, plain nixpkgs**: Fastest but abandons the lockfile pipeline

## Gotchas

1. **Pinned git revs**: `fetchGit` without a `rev` fails in pure mode; bump revs deliberately
2. **projectName must match**: `package.nix`'s `projectName = "someProject"` must match `pyproject.toml` `[project] name`
3. **Namespaced venv**: Lives at `someProject-env/` to avoid collision with system `python3`
4. **Editable source**: Only `requirements.bak.txt` should be edited; all other files are generated

## Commands Reference

| Command | Effect |
|---------|--------|
| `nix build` | Build the package (needs network first run) |
| `nix run` | Build and open HTML report in browser |
| `nix develop` | Enter dev shell with locked Python env |
| `./nix/update-lock.sh` | Regenerate lockfile from `requirements.bak.txt` |
| `./nix/Lock2LocalPkgs.sh` | Set `flake.lock` to local nixpkgs for faster builds |
| `result/bin/someProject-env/python3 <script>` | Run script in locked venv |
| `result/bin/someProject` | Open HTML report |
