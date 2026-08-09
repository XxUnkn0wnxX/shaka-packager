#!/usr/bin/env zsh

set -euo pipefail

usage() {
  /bin/cat <<'EOF'
Usage: build-local.zsh [--help]

Build Shaka Packager with vendored dependencies linked into one executable,
then copy only that executable to the dist folder.

Environment:
  SHAKA_BUILD_DIR   Build directory (default: <repo-root>/builder-local)
  SHAKA_DIST_DIR    Output directory (default: <repo-root>/dist-local)
  SHAKA_JOBS        Parallel jobs for Ninja (default: CPU count)

Commands and toolchain are pinned for this Big Sur Intel setup.
EOF
}

if (( $# > 1 )); then
  echo "Unexpected arguments. Use --help." >&2
  usage >&2
  exit 1
fi

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Unsupported argument: $1" >&2
    usage >&2
    exit 1
    ;;
esac

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:A}"

resolve_build_path() {
  local target="$1"
  if [[ "$target" == /* ]]; then
    print -r -- "$target"
  else
    print -r -- "$REPO_ROOT/$target"
  fi
}

BUILD_DIR="${SHAKA_BUILD_DIR:-builder-local}"
DIST_DIR="${SHAKA_DIST_DIR:-dist-local}"
BUILD_DIR="$(resolve_build_path "$BUILD_DIR")"
DIST_DIR="$(resolve_build_path "$DIST_DIR")"
BUILD_DIR="${BUILD_DIR:A}"
DIST_DIR="${DIST_DIR:A}"

if [[ -n "${SHAKA_JOBS:-}" ]]; then
  JOBS="${SHAKA_JOBS}"
else
  JOBS="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 1)"
fi

if [[ ! "$JOBS" == <-> ]] || (( JOBS < 1 )); then
  echo "Invalid SHAKA_JOBS value: $JOBS" >&2
  exit 1
fi

CMAKE_BIN="/usr/local/bin/cmake"
NINJA_BIN="/usr/local/bin/ninja"
GIT_BIN="/usr/local/bin/git"
PYTHON_BIN="/usr/local/bin/python3"
CLANG_BIN="/usr/bin/clang"
CLANGPP_BIN="/usr/bin/clang++"
XCRUN_BIN="/usr/bin/xcrun"
BREW_BIN="/usr/local/bin/brew"

check_tool() {
  local bin_path="$1"
  if [[ ! -x "$bin_path" ]]; then
    echo "Missing required binary: $bin_path" >&2
    exit 1
  fi
}

check_tool "$CMAKE_BIN"
check_tool "$NINJA_BIN"
check_tool "$GIT_BIN"
check_tool "$PYTHON_BIN"
check_tool "$CLANG_BIN"
check_tool "$CLANGPP_BIN"
check_tool "$XCRUN_BIN"

"$CMAKE_BIN" --version >/dev/null
"$NINJA_BIN" --version >/dev/null
"$GIT_BIN" --version >/dev/null
"$PYTHON_BIN" --version >/dev/null
"$CLANG_BIN" --version >/dev/null
"$CLANGPP_BIN" --version >/dev/null

SDKROOT_PATH="$("$XCRUN_BIN" --sdk macosx --show-sdk-path)"
MACOSX_DEPLOYMENT_TARGET="11.0"

"$GIT_BIN" -C "$REPO_ROOT" submodule update --init --recursive --force

ABSL_HEADER_LINK="/usr/local/include/absl"
ABSL_RESTORE_REQUIRED=0

cleanup_absl() {
  local exit_status=$?
  trap - EXIT

  if (( ABSL_RESTORE_REQUIRED )) && ! "$BREW_BIN" link abseil; then
    echo "Failed to restore Homebrew abseil link at /usr/local/include/absl." >&2
    exit_status=1
  fi

  exit "$exit_status"
}

trap cleanup_absl EXIT

# Apple Clang 13 implicitly searches /usr/local/include.  Temporarily unlink
# Homebrew Abseil so its headers cannot be mixed with the vendored Abseil.
if [[ -e "$ABSL_HEADER_LINK" && ! -L "$ABSL_HEADER_LINK" ]]; then
  echo "Refusing to continue: non-symlink /usr/local/include/absl exists." >&2
  echo "Script only handles Homebrew-linked /usr/local/include/absl." >&2
  exit 1
fi

if [[ -L "$ABSL_HEADER_LINK" ]]; then
  if [[ ! -x "$BREW_BIN" ]]; then
    echo "Conflicting /usr/local/include/absl requires Homebrew, but $BREW_BIN is missing." >&2
    exit 1
  fi

  ABSL_RESOLVED="${ABSL_HEADER_LINK:A}"
  if [[ "$ABSL_RESOLVED" == /usr/local/Cellar/abseil/*/include/absl ]]; then
    ABSL_RESTORE_REQUIRED=1
    "$BREW_BIN" unlink abseil
  else
    echo "Refusing to continue: /usr/local/include/absl is not Homebrew abseil." >&2
    echo "Target: $ABSL_RESOLVED" >&2
    exit 1
  fi
fi

run_clean_env() {
  /usr/bin/env -i \
    HOME="${HOME:-$REPO_ROOT}" \
    USER="${USER:-${LOGNAME:-root}}" \
    LOGNAME="${LOGNAME:-${USER:-root}}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    SDKROOT="$SDKROOT_PATH" \
    MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    "$@"
}

# libwebm probes for the positive spellings before adding them globally.  The
# paired spellings prevent re-addition while leaving the diagnostics disabled;
# otherwise valid C++17 generated protobuf code fails under Shaka's -Werror.
CMFLAGS='-Wc++14-compat -Wno-c++14-compat -Wc++17-compat -Wno-c++17-compat -Wc++20-compat -Wno-c++20-compat'

run_clean_env "$CMAKE_BIN" \
  -S "$REPO_ROOT" \
  -B "$BUILD_DIR" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
  -DCMAKE_C_COMPILER="$CLANG_BIN" \
  -DCMAKE_CXX_COMPILER="$CLANGPP_BIN" \
  -DCMAKE_OSX_SYSROOT="$SDKROOT_PATH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DPython3_EXECUTABLE="$PYTHON_BIN" \
  -DBUILD_SHARED_LIBS=OFF \
  -DUSE_SYSTEM_DEPENDENCIES=OFF \
  -DFULLY_STATIC=OFF \
  -DCMAKE_CXX_FLAGS:STRING="$CMFLAGS"

run_clean_env "$CMAKE_BIN" --build "$BUILD_DIR" --target packager --parallel "$JOBS"

PACKAGER_BIN="$BUILD_DIR/packager/packager"
if [[ ! -x "$PACKAGER_BIN" ]]; then
  echo "Expected binary not found: $PACKAGER_BIN" >&2
  exit 1
fi

/bin/mkdir -p "$DIST_DIR"
"$CMAKE_BIN" -E copy "$PACKAGER_BIN" "$DIST_DIR/packager"
/bin/chmod +x "$DIST_DIR/packager"

"$DIST_DIR/packager" --version
/usr/bin/file "$DIST_DIR/packager"
/usr/bin/otool -L "$DIST_DIR/packager"
