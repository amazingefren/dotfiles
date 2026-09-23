#!/bin/sh
# Bootstrap LAYA's private Python environment and, by default, its MLX model.
# Python is pinned here so synced dotfiles behave the same on every machine.
set -eu

PYTHON_VERSION=3.12.13
PYTHON_SELECTOR="python@$PYTHON_VERSION"
MODEL_REPO="aac6fef/laya-mlx"
mode=default
runtime_dir=

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--runtime-dir PATH] [--no-model | --jev-only]

  --no-model   Install the pinned MLX dependencies without downloading weights.
  --jev-only   Create the private Python runtime without MLX dependencies or a
               model. This works on platforms that cannot run MLX.
  --runtime-dir PATH
               Store the venv and Hugging Face cache under PATH.
EOF
}

fail() {
  printf 'LAYA bootstrap: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime-dir)
      [ "$#" -ge 2 ] || fail "--runtime-dir needs a path"
      runtime_dir=$2
      shift 2
      ;;
    --no-model)
      [ "$mode" = default ] || fail "--no-model and --jev-only cannot be combined"
      mode=no-model
      shift
      ;;
    --jev-only)
      [ "$mode" = default ] || fail "--no-model and --jev-only cannot be combined"
      mode=jev-only
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
package_dir=$script_dir
if [ -z "$runtime_dir" ]; then
  runtime_dir=$script_dir/../../etc/laya
fi
case "$runtime_dir" in
  /*) ;;
  *) runtime_dir=$(pwd -P)/$runtime_dir ;;
esac
venv_dir=$runtime_dir/venv
hf_home=$runtime_dir/huggingface

if [ "$mode" != jev-only ]; then
  os_name=$(uname -s 2>/dev/null || printf unknown)
  arch_name=$(uname -m 2>/dev/null || printf unknown)
  if [ "$os_name" != Darwin ] || [ "$arch_name" != arm64 ]; then
    fail "MLX requires macOS on Apple Silicon; use --jev-only for the portable API runtime"
  fi
  if ! command -v sw_vers >/dev/null 2>&1; then
    fail "cannot read the macOS version; MLX requires macOS 14 or newer"
  fi
  macos_version=$(sw_vers -productVersion 2>/dev/null || true)
  macos_major=${macos_version%%.*}
  case "$macos_major" in
    ''|*[!0-9]*) fail "cannot read the macOS version; MLX requires macOS 14 or newer" ;;
  esac
  if [ "$macos_major" -lt 14 ]; then
    fail "MLX requires macOS 14 or newer; use --jev-only for the portable API runtime"
  fi
fi

if ! command -v mise >/dev/null 2>&1; then
  fail "mise is required; install it from https://mise.jdx.dev/getting-started.html"
fi

mkdir -p "$runtime_dir"
printf 'LAYA bootstrap: mise Python %s\n' "$PYTHON_VERSION"
mise install "$PYTHON_SELECTOR"
if ! mise_dir=$(mise where "$PYTHON_SELECTOR"); then
  fail "mise could not locate $PYTHON_SELECTOR after installation"
fi
[ -d "$mise_dir" ] || fail "mise returned a missing Python directory: $mise_dir"
mise_dir=$(CDPATH= cd "$mise_dir" && pwd -P)
mise_python_home=$(CDPATH= cd "$mise_dir/bin" 2>/dev/null && pwd -P) \
  || fail "mise Python has no bin directory: $mise_dir"

base_python=
for candidate in "$mise_dir/bin/python3.12" "$mise_dir/bin/python3" "$mise_dir/bin/python"; do
  if [ -x "$candidate" ]; then
    base_python=$candidate
    break
  fi
done
[ -n "$base_python" ] || fail "mise Python executable was not found under $mise_dir/bin"
actual_version=$("$base_python" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')
[ "$actual_version" = "$PYTHON_VERSION" ] \
  || fail "mise selected Python $actual_version; expected $PYTHON_VERSION"

venv_matches_mise_python() {
  [ -f "$venv_dir/pyvenv.cfg" ] && [ -x "$venv_dir/bin/python" ] || return 1
  cfg_home=$(awk -F= '$1 ~ /^[[:space:]]*home[[:space:]]*$/ { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$venv_dir/pyvenv.cfg")
  cfg_version=$(awk -F= '$1 ~ /^[[:space:]]*version[[:space:]]*$/ { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$venv_dir/pyvenv.cfg")
  [ "$cfg_version" = "$PYTHON_VERSION" ] || return 1
  [ -d "$cfg_home" ] || return 1
  cfg_home=$(CDPATH= cd "$cfg_home" 2>/dev/null && pwd -P) || return 1
  [ "$cfg_home" = "$mise_python_home" ]
}

if [ -e "$venv_dir" ] || [ -L "$venv_dir" ]; then
  if venv_matches_mise_python; then
    printf 'LAYA bootstrap: reusing venv from mise Python %s\n' "$PYTHON_VERSION"
  else
    backup_dir=$runtime_dir/venv.previous
    if [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; then
      backup_index=1
      while [ -e "$backup_dir.$backup_index" ] || [ -L "$backup_dir.$backup_index" ]; do
        backup_index=$((backup_index + 1))
      done
      backup_dir=$backup_dir.$backup_index
    fi
    mv "$venv_dir" "$backup_dir"
    printf 'LAYA bootstrap: moved incompatible venv to %s\n' "$backup_dir"
  fi
fi

if [ ! -x "$venv_dir/bin/python" ]; then
  printf 'LAYA bootstrap: creating %s\n' "$venv_dir"
  "$base_python" -m venv "$venv_dir"
  venv_matches_mise_python || fail "created venv does not use mise Python $PYTHON_VERSION"
fi

venv_python=$venv_dir/bin/python
if [ "$mode" != jev-only ]; then
  requirements=$package_dir/requirements.txt
  [ -f "$requirements" ] || fail "requirements file is missing: $requirements"
  printf 'LAYA bootstrap: installing pinned MLX dependencies\n'
  "$venv_python" -m pip install --no-input --disable-pip-version-check -r "$requirements"
  if [ "$mode" = default ]; then
    mkdir -p "$hf_home"
    export HF_HOME=$hf_home
    export HF_HUB_DISABLE_TELEMETRY=1
    printf 'LAYA bootstrap: downloading %s into %s\n' "$MODEL_REPO" "$hf_home"
    "$venv_python" -c 'import sys; from huggingface_hub import snapshot_download; snapshot_download(repo_id=sys.argv[1], allow_patterns=["*.safetensors", "*.npz", "*.json", "*.model", "*.txt", "*.jinja", "*.tiktoken", "*.yaml", "*.yml"])' "$MODEL_REPO"
  fi
fi

printf 'LAYA bootstrap: Python %s at %s\n' "$PYTHON_VERSION" "$venv_python"
case "$mode" in
  default) printf 'LAYA bootstrap: MLX dependencies and default model are ready\n' ;;
  no-model) printf 'LAYA bootstrap: MLX dependencies are ready; no model was downloaded\n' ;;
  jev-only) printf 'LAYA bootstrap: portable API runtime is ready; MLX was not installed\n' ;;
esac
