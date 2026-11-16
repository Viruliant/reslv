# package.nix
#
# Goal:
#   Keep flake.nix as small as possible and move the uv2nix /
#   pyproject-nix setup into package.nix.
#
# info:
#   - update-lock.sh will regenerate:
#       pyproject.toml
#       uv.lock
#       make sure you manage these files with git in case
#       we need to go back
#   - myCustomOverrides.nix
#       Useful place to force particular nixpkgs versions
#       of packages such as: torch pyside6 shiboken6 etc.
#
# Usage:
#   nix build
#   nix run
#
# so everything must be self-contained.

{ pkgs }:

let
  inherit (pkgs) lib;

  # Pull pyproject-nix ecosystem directly.
  # Pinned revs: fetchGit without a rev is an "unlocked" input and fails
  # in pure evaluation mode (default for `nix build` / `nix develop`).
  pyproject-nix = import (builtins.fetchGit {
    url = "https://github.com/pyproject-nix/pyproject.nix.git";
    rev = "ddc400a6883b042646d0940e65971bb7f7e96107";
  }) {
    inherit lib;
  };

  uv2nix = import (builtins.fetchGit {
    url = "https://github.com/pyproject-nix/uv2nix.git";
    rev = "a541fda20d6784d88789cfcb221638b7c25a23dd";
  }) {
    inherit pyproject-nix lib;
  };

  pyproject-build-systems = import (builtins.fetchGit {
    url = "https://github.com/pyproject-nix/build-system-pkgs.git";
    rev = "953d35d03a51dbecaf3feb3fb679eb63e90ebeb4";
  }) {
    inherit pyproject-nix uv2nix lib;
  };
  # python312: numpy==1.26.4 (pinned in uv.lock) only ships wheels up to
  # cp312; on 3.13 uv2nix would have to build numpy from source.
  python = pkgs.python312;

  # Load workspace Reads:
  #   nix/pyproject.toml
  #   nix/uv.lock
  workspace = uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = ./nix;
  };

  # Convert uv.lock into an overlay
  # Prefer wheels where available because:
  #   - faster builds
  #   - fewer compilation surprises
  uvLockedOverlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  myCustomOverrides =
    import ./nix/myCustomOverrides.nix {
      inherit pkgs python;
    };

  # Construct final python package set Order matters:
  #   1. build-system packages
  #   2. uv lockfile packages
  #   3. custom fixes
  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages {
      inherit python;
    }).overrideScope (
      lib.composeManyExtensions [
        pyproject-build-systems.overlays.default
        uvLockedOverlay
        myCustomOverrides
      ]
    );

  # in pyproject.toml Must match:
  #   [project]
  #   name = "rslv"
  projectName = "rslv";

  # Build the runtime virtual environment
  # workspace.deps.default comes from pyproject.toml
  appPythonEnv =
    pythonSet.mkVirtualEnv
      "${projectName}-env"
      workspace.deps.default;
  # For now we only need the virtualenv.
  # If the generated package exists, you can expose it:
  #   projectPkg = pythonSet.${projectName};

in

####################################################################

pkgs.stdenv.mkDerivation {
  pname = projectName;
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = [
    appPythonEnv
  ];
  # bin/rslv-env/ = the full locked venv, namespaced (python3, python, etc.)
  # reslv is pure Python — installed by copying into site-packages (no pip).
  # nothing shadows the system python3.
  # Suffixed -env so it can never collide with the rslv launcher.
  installPhase = ''
    mkdir -p $out/bin
    # Make a writable copy of the venv (Nix store is read-only)
    cp -a ${appPythonEnv} $out/bin/${projectName}-env
    chmod -R u+w $out/bin/${projectName}-env

    # Install reslv (pure Python, no pip) — copy into site-packages
    SITE_PKGS="$out/bin/${projectName}-env/lib/python3.12/site-packages"
    cp -r reslv "$SITE_PKGS/"

    # Create launcher that calls python -m reslv.reslv
    cat > $out/bin/reslv <<EOF
    #!${pkgs.runtimeShell}
    exec $out/bin/${projectName}-env/bin/python3 -m reslv.reslv "\$@"
    EOF
    chmod +x $out/bin/reslv
  '';

  meta = with lib; {
    description = "Recursive file dependency resolver — resolves {{{path:...}}} and {{{var_str:...}}} tags";
    platforms = platforms.all;
    mainProgram = "reslv";
  };
}
