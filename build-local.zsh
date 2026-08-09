#!/usr/bin/env zsh

set -euo pipefail

usage() {
  /bin/cat <<'EOF'
Usage: build-local.zsh [--clean] [--libs] [--help]

Build Shaka Packager on this machine and publish the requested artifacts into:
  <dist-root>/<VERSION>/packager
and, with --libs:
  <dist-root>/<VERSION>/lib/libpackager.dylib

Options:
  --clean   Run one upfront cleanup of script-managed build dirs only:
            <build-root>, build, build-*, builder, builder-* and cmake-build-*.
            Dist is never touched by --clean.
  --libs    Configure libpackager as shared (default is static). Vendored
            third-party dependencies remain static.
  --help    Show this help text.

Environment:
  SHAKA_BUILD_DIR   Build root override (default: <repo>/builder)
  SHAKA_DIST_DIR    Dist root override (default: <repo>/dist)
  SHAKA_JOBS        Parallel jobs (default: logical CPUs, fallback ncpu, fallback 1)
EOF
}

die() {
  print -u2 -- "build-local.zsh: $*"
  exit 1
}

resolve_child_path() {
  local value="$1"
  local abs
  if [[ "$value" == /* ]]; then
    abs="$value"
  else
    abs="$REPO_ROOT/$value"
  fi
  abs="${abs:A}"
  if [[ "$abs" == "$REPO_ROOT/"* ]]; then
    print -r -- "$abs"
    return
  fi
  die "Path is outside repo root: $value -> $abs"
}

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:A}"

CLEAN_REQUESTED=0
BUILD_SHARED=0
HELP_REQUESTED=0

typeset -i CLEAN_SEEN=0
typeset -i LIBS_SEEN=0
typeset -i HELP_SEEN=0

for arg in "$@"; do
  case "$arg" in
    --clean)
      (( CLEAN_SEEN )) && die "Duplicate flag: --clean"
      CLEAN_SEEN=1
      CLEAN_REQUESTED=1
      ;;
    --libs)
      (( LIBS_SEEN )) && die "Duplicate flag: --libs"
      LIBS_SEEN=1
      BUILD_SHARED=1
      ;;
    --help|-h)
      (( HELP_SEEN )) && die "Duplicate flag: --help"
      HELP_SEEN=1
      HELP_REQUESTED=1
      ;;
    *)
      usage >&2
      die "Unknown flag: $arg"
      ;;
  esac
done

if (( HELP_REQUESTED )); then
  usage
  exit 0
fi

CMAKE_BIN="/usr/local/bin/cmake"
NINJA_BIN="/usr/local/bin/ninja"
GIT_BIN="/usr/local/bin/git"
PYTHON_BIN="/usr/local/bin/python3"
CLANG_BIN="/usr/bin/clang"
CLANGPP_BIN="/usr/bin/clang++"
XCRUN_BIN="/usr/bin/xcrun"
BREW_BIN="/usr/local/bin/brew"

require_tool() {
  local bin_path="$1"
  if [[ ! -x "$bin_path" ]]; then
    die "Missing required tool: $bin_path"
  fi
}

require_tool "$CMAKE_BIN"
require_tool "$NINJA_BIN"
require_tool "$GIT_BIN"
require_tool "$PYTHON_BIN"
require_tool "$CLANG_BIN"
require_tool "$CLANGPP_BIN"
require_tool "$XCRUN_BIN"

RESTORE_ABSL=1
ABSL_RESTORE_REQUIRED=0
CLEANUP_DONE=0
PUBLISH_SUCCESS=0
VERSION_NAME=""
VERSION_DIR=""
STAGE_TMP_DIR=""
VERSION_BACKUP_DIR=""

cleanup() {
  set +e
  local -i exit_status=${1:-0}
  local -i clean_failed=0
  local -i preserve_backup=0
  local backup_payload=""

  if (( CLEANUP_DONE )); then
    exit "$exit_status"
  fi
  CLEANUP_DONE=1
  trap - EXIT INT TERM HUP

  if [[ -n "${VERSION_BACKUP_DIR}" && -n "${VERSION_NAME}" ]]; then
    backup_payload="$VERSION_BACKUP_DIR/$VERSION_NAME"
  fi

  if (( ! PUBLISH_SUCCESS )) && [[ -e "$backup_payload" || -L "$backup_payload" ]]; then
    if [[ -e "$VERSION_DIR" || -L "$VERSION_DIR" ]]; then
      if ! /bin/rm -rf "$VERSION_DIR"; then
        print -u2 "Failed to remove incomplete publish at ${VERSION_DIR}."
        clean_failed=1
        preserve_backup=1
      fi
    fi
    if (( ! preserve_backup )); then
      if ! /bin/mv "$backup_payload" "$VERSION_DIR"; then
        print -u2 "Failed to restore prior ${VERSION_DIR} from backup."
        clean_failed=1
        preserve_backup=1
      fi
    fi
  fi

  if [[ -n "${STAGE_TMP_DIR}" && -e "$STAGE_TMP_DIR" ]]; then
    if ! /bin/rm -rf "$STAGE_TMP_DIR"; then
      print -u2 "Failed to remove staging directory: $STAGE_TMP_DIR"
      clean_failed=1
    fi
  fi
  if [[ -n "${VERSION_BACKUP_DIR}" && -e "$VERSION_BACKUP_DIR" ]]; then
    if (( preserve_backup )); then
      print -u2 "Prior distribution preserved at: $VERSION_BACKUP_DIR"
    elif ! /bin/rm -rf "$VERSION_BACKUP_DIR"; then
      print -u2 "Failed to remove backup directory: $VERSION_BACKUP_DIR"
      clean_failed=1
    fi
  fi

  if (( RESTORE_ABSL )) && (( ABSL_RESTORE_REQUIRED )); then
    if ! "$BREW_BIN" link abseil; then
      print -u2 "Failed to restore Homebrew abseil link at /usr/local/include/absl."
      clean_failed=1
    fi
  fi

  if (( clean_failed && exit_status == 0 )); then
    exit_status=1
  fi
  exit "$exit_status"
}

handle_signal() {
  local signal_name="$1"
  local -i exit_status=1

  case "$signal_name" in
    HUP)  exit_status=129 ;;
    INT)  exit_status=130 ;;
    TERM) exit_status=143 ;;
  esac

  cleanup "$exit_status"
}

trap 'cleanup "$?"' EXIT
trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

if (( BUILD_SHARED )); then
  BUILD_KIND="shared"
else
  BUILD_KIND="static"
fi

if ! PACKAGER_TAG="$("$GIT_BIN" -C "$REPO_ROOT" describe --tags --match 'v[0-9]*' --abbrev=0 HEAD 2>/dev/null)"; then
  die "Failed to resolve release tag from git history."
fi
if [[ "$PACKAGER_TAG" == "" ]]; then
  die "No matching release tag found for HEAD."
fi
if [[ ! "$PACKAGER_TAG" =~ '^v([0-9]+)\.([0-9]+)(\.[0-9]+)?$' ]]; then
  die "Unexpected or unsupported release tag: ${PACKAGER_TAG}"
fi
VERSION_NAME="${PACKAGER_TAG#v}"
PACKAGER_SHORT_SHA="$("$GIT_BIN" -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
PACKAGER_VERSION="${PACKAGER_TAG}-${PACKAGER_SHORT_SHA}"

if [[ -n "${SHAKA_BUILD_DIR-}" ]]; then
  BUILD_ROOT="$(resolve_child_path "$SHAKA_BUILD_DIR")"
else
  BUILD_ROOT="$(resolve_child_path "builder")"
fi

if [[ -n "${SHAKA_DIST_DIR-}" ]]; then
  DIST_ROOT="$(resolve_child_path "$SHAKA_DIST_DIR")"
else
  DIST_ROOT="$(resolve_child_path "dist")"
fi
if [[ "$BUILD_ROOT" == "$DIST_ROOT" || "$BUILD_ROOT" == "$DIST_ROOT/"* || "$DIST_ROOT" == "$BUILD_ROOT/"* ]]; then
  die "Build and dist roots must be distinct and non-overlapping: $BUILD_ROOT vs $DIST_ROOT"
fi

if [[ -n "${SHAKA_JOBS-}" ]]; then
  JOBS="${SHAKA_JOBS}"
else
  if JOBS="$(
    /usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null
  )"; then
    true
  elif JOBS="$(
    /usr/sbin/sysctl -n hw.ncpu 2>/dev/null
  )"; then
    true
  else
    JOBS=1
  fi
fi
if [[ ! "$JOBS" == <-> ]] || (( JOBS < 1 )); then
  die "Invalid SHAKA_JOBS value: ${JOBS}"
fi

if (( CLEAN_REQUESTED )); then
  typeset -A CLEAN_PATHS=()
  typeset -a TARGET_PATHS=()
  typeset -a CLEAN_CANDIDATES=(
    "$BUILD_ROOT"(N)
    "$REPO_ROOT"/build(N)
    "$REPO_ROOT"/build-*(N)
    "$REPO_ROOT"/builder(N)
    "$REPO_ROOT"/builder-*(N)
    "$REPO_ROOT"/cmake-build-*(N)
  )
  for candidate in "${CLEAN_CANDIDATES[@]}"; do
    if [[ ! -d "$candidate" && ! -L "$candidate" ]]; then
      continue
    fi
    candidate="${candidate:A}"
    if [[ "$candidate" != "$REPO_ROOT" && "$candidate" != "$REPO_ROOT"/* ]]; then
      die "Unsafe cleanup candidate outside repo: $candidate"
    fi
    if [[ "$candidate" == "$DIST_ROOT" || "$candidate" == "$DIST_ROOT/"* || "$DIST_ROOT" == "$candidate" || "$DIST_ROOT" == "$candidate/"* ]]; then
      die "Refusing to delete dist path during clean: $candidate"
    fi
    tracked_file="$("$GIT_BIN" -C "$REPO_ROOT" ls-files -- "${candidate#$REPO_ROOT/}")"
    if [[ -n "$tracked_file" ]]; then
      die "Refusing to delete tracked path during clean: $candidate"
    fi
    if [[ -z "${CLEAN_PATHS[$candidate]-}" ]]; then
      CLEAN_PATHS["$candidate"]=1
      TARGET_PATHS+=("$candidate")
    fi
  done
  for candidate in "${TARGET_PATHS[@]}"; do
    print -- "Removing build directory: $candidate"
    /bin/rm -rf "$candidate"
  done
  if (( ${#TARGET_PATHS[@]} == 0 )); then
    print -- "No build directories found; continuing."
  fi
fi

SDKROOT_PATH="$("$XCRUN_BIN" --sdk macosx --show-sdk-path)"
if [[ -z "$SDKROOT_PATH" ]]; then
  die "Failed to resolve macOS SDK path."
fi
MACOSX_DEPLOYMENT_TARGET="11.0"

"$CMAKE_BIN" --version >/dev/null
"$NINJA_BIN" --version >/dev/null
"$GIT_BIN" --version >/dev/null
"$PYTHON_BIN" --version >/dev/null

ABSL_HEADER_LINK="/usr/local/include/absl"
if [[ -e "$ABSL_HEADER_LINK" && ! -L "$ABSL_HEADER_LINK" ]]; then
  die "/usr/local/include/absl exists and is not a symlink."
fi

if [[ -L "$ABSL_HEADER_LINK" ]]; then
  require_tool "$BREW_BIN"
  ABSL_HEADER_TARGET="${ABSL_HEADER_LINK:A}"
  if [[ "$ABSL_HEADER_TARGET" == /usr/local/Cellar/abseil/*/include/absl ]]; then
    ABSL_RESTORE_REQUIRED=1
    if ! "$BREW_BIN" unlink abseil; then
      die "Failed to temporarily unlink Homebrew abseil."
    fi
  else
    die "Abseil include link is outside Homebrew cellar: $ABSL_HEADER_TARGET"
  fi
fi

run_clean_env() {
  local _home="${HOME:-$REPO_ROOT}"
  local _user="${USER:-${LOGNAME:-$(/usr/bin/whoami)}}"
  local _logname="${LOGNAME:-$_user}"
  /usr/bin/env -i \
    HOME="$_home" \
    USER="$_user" \
    LOGNAME="$_logname" \
    TMPDIR="${TMPDIR:-/tmp}" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    SDKROOT="$SDKROOT_PATH" \
    MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
    "$@"
}

"$GIT_BIN" -C "$REPO_ROOT" submodule update --force --recursive --init

BUILD_DIR="$BUILD_ROOT/$VERSION_NAME/$BUILD_KIND"
DIST_DIR="$DIST_ROOT/$VERSION_NAME"
VERSION_DIR="$DIST_DIR"

CMFLAGS='-Wc++14-compat -Wno-c++14-compat -Wc++17-compat -Wno-c++17-compat -Wc++20-compat -Wno-c++20-compat'

if (( BUILD_SHARED )); then
  SHARED_FLAGS=(
    -DBUILD_SHARED_LIBS:BOOL=ON
    -DCMAKE_BUILD_WITH_INSTALL_RPATH:BOOL=ON
    -DCMAKE_INSTALL_NAME_DIR:STRING=@rpath
    -DCMAKE_INSTALL_RPATH:STRING=@executable_path/lib
  )
else
  SHARED_FLAGS=(
    -DBUILD_SHARED_LIBS:BOOL=OFF
  )
fi

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
  -DPACKAGER_VERSION="$PACKAGER_VERSION" \
  -DUSE_SYSTEM_DEPENDENCIES=OFF \
  -DFULLY_STATIC=OFF \
  -DCMAKE_CXX_FLAGS:STRING="$CMFLAGS" \
  "${SHARED_FLAGS[@]}"

run_clean_env "$CMAKE_BIN" \
  --build "$BUILD_DIR" \
  --target packager \
  --parallel "$JOBS"

PACKAGER_BIN="$BUILD_DIR/packager/packager"
if [[ ! -x "$PACKAGER_BIN" ]]; then
  die "Expected binary not found: $PACKAGER_BIN"
fi

/bin/mkdir -p "$DIST_ROOT"
STAGE_TMP_DIR="$(
  /usr/bin/mktemp -d "${DIST_ROOT}/.packager-stage.XXXXXX"
)"
STAGE_VERSION_DIR="$STAGE_TMP_DIR/$VERSION_NAME"
/bin/mkdir -p "$STAGE_VERSION_DIR"
/bin/cp "$PACKAGER_BIN" "$STAGE_VERSION_DIR/packager"
/bin/chmod +x "$STAGE_VERSION_DIR/packager"

if (( BUILD_SHARED )); then
  if [[ ! -f "$BUILD_DIR/packager/libpackager.dylib" ]]; then
    die "Expected shared library missing: $BUILD_DIR/packager/libpackager.dylib"
  fi
  /bin/mkdir -p "$STAGE_VERSION_DIR/lib"
  /bin/cp "$BUILD_DIR/packager/libpackager.dylib" "$STAGE_VERSION_DIR/lib/libpackager.dylib"
fi

run_clean_env "$STAGE_VERSION_DIR/packager" --version
/usr/bin/file "$STAGE_VERSION_DIR/packager"
PACKAGER_OTOOL_OUT="$(/usr/bin/otool -L "$STAGE_VERSION_DIR/packager")"
PACKAGER_RPATH_OUT="$(/usr/bin/otool -l "$STAGE_VERSION_DIR/packager")"
print -- "$PACKAGER_OTOOL_OUT"
if (( BUILD_SHARED )); then
  if [[ ! "$PACKAGER_OTOOL_OUT" == *"@rpath/libpackager.dylib"* ]]; then
    die "Shared build check: missing @rpath/libpackager.dylib in packager linkage."
  fi
  if [[ ! "$PACKAGER_RPATH_OUT" == *"@executable_path/lib"* ]]; then
    die "Shared build check: missing @executable_path/lib in packager linkage."
  fi
fi
unset PACKAGER_OTOOL_OUT PACKAGER_RPATH_OUT

if (( BUILD_SHARED )); then
  DYLIB_OTOOL_OUT="$(/usr/bin/otool -L "$STAGE_VERSION_DIR/lib/libpackager.dylib")"
  DYLIB_LC_OUT="$(/usr/bin/otool -l "$STAGE_VERSION_DIR/lib/libpackager.dylib")"
  print -- "$DYLIB_OTOOL_OUT"
  if [[ "$DYLIB_OTOOL_OUT" != *"@rpath/libpackager.dylib"* && "$DYLIB_OTOOL_OUT" != *"$STAGE_VERSION_DIR/lib/libpackager.dylib"* ]]; then
    die "Shared build check: missing expected dylib identity in packager shared library output."
  fi
  if [[ "$DYLIB_LC_OUT" != *"name @rpath/libpackager.dylib"* ]]; then
    die "Shared build check: missing LC_ID_DYLIB @rpath/libpackager.dylib."
  fi
  unset DYLIB_OTOOL_OUT
  unset DYLIB_LC_OUT
fi

if [[ -e "$VERSION_DIR" || -L "$VERSION_DIR" ]]; then
  VERSION_BACKUP_DIR="$(
    /usr/bin/mktemp -d "${DIST_ROOT}/.packager-backup.XXXXXX"
  )"
  /bin/mv "$VERSION_DIR" "$VERSION_BACKUP_DIR/$VERSION_NAME"
fi

if ! /bin/mv "$STAGE_VERSION_DIR" "$VERSION_DIR"; then
  die "Failed to publish ${VERSION_DIR}."
fi
PUBLISH_SUCCESS=1

if [[ -n "${VERSION_BACKUP_DIR}" ]]; then
  /bin/rm -rf "$VERSION_BACKUP_DIR"
  VERSION_BACKUP_DIR=""
fi

if [[ -n "$STAGE_TMP_DIR" ]]; then
  /bin/rm -rf "$STAGE_TMP_DIR"
  STAGE_TMP_DIR=""
fi

print -- "Published: ${VERSION_DIR}"
