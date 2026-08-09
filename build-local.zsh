#!/usr/bin/env zsh

set -euo pipefail

usage() {
  /bin/cat <<'EOF'
Usage: build-local.zsh [--clean] [--libs] [--help]

Build Shaka Packager on this machine and publish the requested artifacts into:
  <dist-root>/<VERSION>/packager
and, with --libs:
  <dist-root>/<VERSION>/lib/libpackager.dylib

Backends:
  Modern (CMake): Uses CMakeLists.txt.
  Legacy (GYP): Uses gyp_packager.py, DEPS, and packager/packager.gyp.

Options:
  --clean   Run one upfront cleanup of script-managed build dirs only:
            <build-root>, build, build-*, builder, builder-*, out, out-*,
            out_*, cmake-build-*.
            Dist is never touched by --clean.
  --libs    Configure libpackager as shared (default is static). Vendored
            third-party dependencies remain static.
  --help    Show this help text.

Environment:
  SHAKA_BUILD_DIR   Build root override (default: <repo>/builder)
  SHAKA_DIST_DIR    Dist root override (default: <repo>/dist)
  SHAKA_JOBS        Parallel jobs (default: 8)
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

GIT_BIN="/usr/local/bin/git"
NINJA_BIN="/usr/local/bin/ninja"
CLANG_BIN="/usr/bin/clang"
CLANGPP_BIN="/usr/bin/clang++"
XCRUN_BIN="/usr/bin/xcrun"
CMAKE_BIN="/usr/local/bin/cmake"
PYTHON_BIN_LEGACY="/usr/bin/python3"
PYTHON_BIN_MODERN="/usr/local/bin/python3"
BREW_BIN="/usr/local/bin/brew"
OTOOL_BIN="/usr/bin/otool"
FILE_BIN="/usr/bin/file"
INSTALL_NAME_TOOL_BIN="/usr/bin/install_name_tool"
AWK_BIN="/usr/bin/awk"

MODERN_MARKER="$REPO_ROOT/CMakeLists.txt"
LEGACY_MARKERS=(
  "$REPO_ROOT/gyp_packager.py"
  "$REPO_ROOT/DEPS"
  "$REPO_ROOT/packager/packager.gyp"
)

BUILD_BACKEND=""

if [[ -f "$MODERN_MARKER" ]]; then
  BUILD_BACKEND="modern"
fi

typeset -i LEGACY_MARKER_COUNT=0
typeset -a MISSING_LEGACY_MARKERS=()
for marker in "${LEGACY_MARKERS[@]}"; do
  if [[ -e "$marker" ]]; then
    (( ++LEGACY_MARKER_COUNT ))
  else
    MISSING_LEGACY_MARKERS+=("${marker#$REPO_ROOT/}")
  fi
done

if [[ -n "$BUILD_BACKEND" && "$LEGACY_MARKER_COUNT" -gt 0 ]]; then
  die "Backend ambiguity: both modern CMake and legacy GYP markers are present."
fi

if [[ -z "$BUILD_BACKEND" && "$LEGACY_MARKER_COUNT" -eq 0 ]]; then
  die "No supported backend markers found. Expected CMakeLists.txt or {gyp_packager.py, DEPS, packager/packager.gyp}."
fi

if [[ -z "$BUILD_BACKEND" && "$LEGACY_MARKER_COUNT" -lt "${#LEGACY_MARKERS[@]}" ]]; then
  die "Partial legacy marker set found. Missing: ${MISSING_LEGACY_MARKERS[*]}"
fi

if [[ "$BUILD_BACKEND" == "" ]]; then
  BUILD_BACKEND="legacy"
fi

require_tool() {
  local bin_path="$1"
  if [[ ! -x "$bin_path" ]]; then
    die "Missing required tool: $bin_path"
  fi
}

require_tool "$GIT_BIN"
require_tool "$NINJA_BIN"
require_tool "$CLANG_BIN"
require_tool "$CLANGPP_BIN"
require_tool "$XCRUN_BIN"
require_tool "$OTOOL_BIN"
require_tool "$FILE_BIN"
require_tool "$AWK_BIN"

if [[ "$BUILD_BACKEND" == "modern" ]]; then
  require_tool "$CMAKE_BIN"
  require_tool "$PYTHON_BIN_MODERN"
  VERSION_PYTHON_BIN="$PYTHON_BIN_MODERN"
else
  require_tool "$PYTHON_BIN_LEGACY"
  VERSION_PYTHON_BIN="$PYTHON_BIN_LEGACY"
  if (( BUILD_SHARED )); then
    require_tool "$INSTALL_NAME_TOOL_BIN"
  fi
fi

VERSION_MANIFEST="$REPO_ROOT/.release-please-manifest.json"
CHANGELOG_FILE="$REPO_ROOT/CHANGELOG.md"
VERSION_NAME="$("$VERSION_PYTHON_BIN" -c 'import json
import os
import re
import sys

manifest_path = sys.argv[1]
changelog_path = sys.argv[2]
number = r"(?:0|[1-9][0-9]*)"
version_pattern = re.compile(rf"{number}\.{number}\.{number}")

if os.path.exists(manifest_path):
  try:
    with open(manifest_path, "r", encoding="utf-8") as manifest_file:
      manifest = json.load(manifest_file)
  except (OSError, UnicodeError, json.JSONDecodeError) as error:
    print(f"Unable to read source version from {manifest_path}: {error}",
          file=sys.stderr)
    raise SystemExit(1)

  if not isinstance(manifest, dict) or "." not in manifest:
    print(f"Missing string key \".\" in {manifest_path}", file=sys.stderr)
    raise SystemExit(1)

  version_name = manifest["."]
  if not isinstance(version_name, str):
    print(f"Manifest key \".\" is not a string in {manifest_path}",
          file=sys.stderr)
    raise SystemExit(1)
  if version_pattern.fullmatch(version_name) is None:
    print(f"Invalid source version in manifest key \".\": {version_name}",
          file=sys.stderr)
    raise SystemExit(1)
else:
  heading_pattern = re.compile(
      rf"^## \[({number}\.{number}\.{number})\](?:\(|\s|$)")
  version_name = None
  try:
    with open(changelog_path, "r", encoding="utf-8") as changelog_file:
      for line in changelog_file:
        match = heading_pattern.match(line.rstrip("\r\n"))
        if match is not None:
          version_name = match.group(1)
          break
  except (OSError, UnicodeError) as error:
    print(f"Unable to read source version from {changelog_path}: {error}",
          file=sys.stderr)
    raise SystemExit(1)

  if version_name is None:
    print(f"No strict X.Y.Z release heading found in {changelog_path}.",
          file=sys.stderr)
    raise SystemExit(1)

print(version_name)' "$VERSION_MANIFEST" "$CHANGELOG_FILE")" ||
  die "Failed to resolve Shaka version from source metadata."

VERSION_NAME="${VERSION_NAME//$'\n'/}"

PACKAGER_SHORT_SHA="$("$GIT_BIN" -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
PACKAGER_VERSION="v${VERSION_NAME}-${PACKAGER_SHORT_SHA}"

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
  JOBS=8
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
    "$REPO_ROOT"/out(N)
    "$REPO_ROOT"/out-*(N)
    "$REPO_ROOT"/out_*(N)
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

RESTORE_ABSL=1
ABSL_RESTORE_REQUIRED=0
CLEANUP_DONE=0
PUBLISH_SUCCESS=0
VERSION_DIR=""
STAGE_TMP_DIR=""
VERSION_BACKUP_DIR=""
BUILD_DIR=""
LIBPACKAGER_DYLIB=""

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
    MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    "$@"
}

run_in_legacy_workspace() {
  local workspace="$1"
  shift
  (cd "$workspace" && run_clean_env "$@")
}

collect_libpackager_dependencies() {
  local binary="$1"
  local dep_line
  local -a deps=()
  local -a raw_deps=()
  raw_deps=( ${(f)"$("$OTOOL_BIN" -L "$binary" | "$AWK_BIN" 'NR>1 { print $1 }')"} )
  for dep_line in "${raw_deps[@]}"; do
    if [[ "$dep_line" == *"/libpackager.dylib" ]]; then
      deps+=("$dep_line")
    fi
  done
  for dep_line in "${deps[@]}"; do
    print -r -- "$dep_line"
  done
}

adjust_legacy_shared_stage_artifacts() {
  local staged_packager="$1"
  local staged_dylib="$2"
  local -a libpackager_deps=()
  local dependency
  libpackager_deps=( ${(f)"$(collect_libpackager_dependencies "$staged_packager")"} )
  if (( ${#libpackager_deps[@]} != 1 )); then
    die "Shared legacy validation: expected exactly one libpackager dependency ending /libpackager.dylib, found ${#libpackager_deps[@]}"
  fi
  dependency="${libpackager_deps[1]}"

  if [[ "$dependency" != "@rpath/libpackager.dylib" ]]; then
    "$INSTALL_NAME_TOOL_BIN" -change "$dependency" "@rpath/libpackager.dylib" "$staged_packager"
  fi
  "$INSTALL_NAME_TOOL_BIN" -id "@rpath/libpackager.dylib" "$staged_dylib"
  if [[ "$("$OTOOL_BIN" -l "$staged_packager")" != *"@executable_path/lib"* ]]; then
    "$INSTALL_NAME_TOOL_BIN" -add_rpath "@executable_path/lib" "$staged_packager"
  fi
}

validate_staged_artifacts() {
  local stage_version_dir="$1"
  local staged_packager="$stage_version_dir/packager"
  local -a libpackager_deps=()
  local dependency_output
  local rpath_output
  local dylib_output
  local dylib_lc_output

  if [[ ! -x "$staged_packager" ]]; then
    die "Expected binary not found: $staged_packager"
  fi

  run_clean_env "$staged_packager" --version
  "$FILE_BIN" "$staged_packager"

  dependency_output="$("$OTOOL_BIN" -L "$staged_packager")"
  rpath_output="$("$OTOOL_BIN" -l "$staged_packager")"
  print -- "$dependency_output"
  print -- "$rpath_output"

  if (( BUILD_SHARED )); then
    libpackager_deps=( ${(f)"$(collect_libpackager_dependencies "$staged_packager")"} )
    if (( ${#libpackager_deps[@]} != 1 )); then
      die "Shared validation: expected exactly one libpackager dependency ending /libpackager.dylib."
    fi
    if [[ "${libpackager_deps[1]}" != "@rpath/libpackager.dylib" ]]; then
      die "Shared validation: missing expected @rpath/libpackager.dylib dependency."
    fi
    if [[ "$rpath_output" != *"@executable_path/lib"* ]]; then
      die "Shared validation: missing expected @executable_path/lib rpath."
    fi

    if [[ ! -f "$stage_version_dir/lib/libpackager.dylib" ]]; then
      die "Expected shared library missing in stage: $stage_version_dir/lib/libpackager.dylib"
    fi
    dylib_output="$("$OTOOL_BIN" -L "$stage_version_dir/lib/libpackager.dylib")"
    dylib_lc_output="$("$OTOOL_BIN" -l "$stage_version_dir/lib/libpackager.dylib")"
    print -- "$dylib_output"
    if [[ "$dylib_output" != *"@rpath/libpackager.dylib"* && "$dylib_output" != *"$stage_version_dir/lib/libpackager.dylib"* ]]; then
      die "Shared validation: missing expected dylib identity in stage output."
    fi
    if [[ "$dylib_lc_output" != *"name @rpath/libpackager.dylib"* ]]; then
      die "Shared validation: missing LC_ID_DYLIB @rpath/libpackager.dylib."
    fi
  fi
}

ensure_legacy_depot_tools() {
  local legacy_tools_dir="$1"
  local legacy_tools_repo="https://chromium.googlesource.com/chromium/tools/depot_tools.git"
  local legacy_tools_rev="592f005eb86412c2f563186e549176d3e2977638"

  if [[ -d "$legacy_tools_dir" ]] && [[ ! -d "$legacy_tools_dir/.git" ]]; then
    die "Legacy tools path exists but is not a git repository: $legacy_tools_dir"
  fi

  if [[ ! -d "$legacy_tools_dir/.git" ]]; then
    /bin/rm -rf "$legacy_tools_dir"
    /bin/mkdir -p "$(dirname "$legacy_tools_dir")"
    run_clean_env "$GIT_BIN" init "$legacy_tools_dir"
    run_clean_env "$GIT_BIN" -C "$legacy_tools_dir" remote add origin "$legacy_tools_repo"
  fi

  run_clean_env "$GIT_BIN" -C "$legacy_tools_dir" remote set-url origin "$legacy_tools_repo"
  run_clean_env "$GIT_BIN" -C "$legacy_tools_dir" fetch --depth=1 --no-tags origin "$legacy_tools_rev"
  run_clean_env "$GIT_BIN" -C "$legacy_tools_dir" checkout --detach --force "$legacy_tools_rev"
}

prepare_legacy_source() {
  local source_dir="$1"
  local source_head="$2"

  /bin/mkdir -p "$source_dir"
  if ! run_clean_env "$GIT_BIN" -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1; then
    run_clean_env "$GIT_BIN" init "$source_dir"
  fi
  run_clean_env "$GIT_BIN" -C "$source_dir" fetch --depth=1 --no-tags "$REPO_ROOT" "$source_head"
  run_clean_env "$GIT_BIN" -C "$source_dir" checkout --detach --force "$source_head"
}

patch_legacy_gyp_clt_detection() {
  local gyp_xcode_emulation="$1"
  if [[ ! -f "$gyp_xcode_emulation" ]]; then
    die "Legacy GYP compatibility file is missing: $gyp_xcode_emulation"
  fi

  run_clean_env "$PYTHON_BIN_LEGACY" -c 'from pathlib import Path
import sys

path = Path(sys.argv[1])
old = "version = re.match(r\u0027(\\d\\.\\d\\.?\\d*)\u0027, version).groups()[0]"
new = "version = re.match(r\u0027(\\d+\\.\\d+(?:\\.\\d+)?)\u0027, version).groups()[0]"
text = path.read_text(encoding="utf-8")

if old in text:
  if text.count(old) != 1:
    raise SystemExit(f"Expected one legacy CLT parser in {path}")
  path.write_text(text.replace(old, new), encoding="utf-8")
elif new not in text:
  print(f"Legacy GYP uses an unrecognized CLT parser; leaving {path} unchanged.",
        file=sys.stderr)
' "$gyp_xcode_emulation"
}

install_legacy_python_shim() {
  local shim_path="$1"
  /bin/mkdir -p "$(dirname "$shim_path")"
  /bin/cat > "$shim_path" <<'SH'
#!/bin/sh
if [ "$#" -ge 1 ]; then
  case "$1" in
    *generate_version_string.py)
      /bin/printf "%s\n" "$PACKAGER_VERSION"
      exit 0
      ;;
  esac
fi
exec /usr/bin/python3 "$@"
SH
  /bin/chmod +x "$shim_path"
}

run_legacy_runhooks() {
  local workspace="$1"
  local build_dir="$2"
  local build_type="$3"
  local gclient_py="$4"
  local depot_tools_dir="${gclient_py:h}"
  local gyp_generator_flags="output_dir=\"$build_dir\""
  local gyp_defines="libpackager_type=${build_type}_library mac_deployment_target=${MACOSX_DEPLOYMENT_TARGET}"

  run_in_legacy_workspace "$workspace" \
    /usr/bin/env \
    DEPOT_TOOLS_UPDATE=0 \
    DEPOT_TOOLS_COLLECT_METRICS=0 \
    DEPOT_TOOLS_METRICS=0 \
    PACKAGER_VERSION="$PACKAGER_VERSION" \
    PATH="$build_dir/tool-shim:$depot_tools_dir:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    GYP_GENERATORS=ninja \
    GYP_GENERATOR_FLAGS="$gyp_generator_flags" \
    GYP_DEFINES="$gyp_defines" \
    "$PYTHON_BIN_LEGACY" \
    "$gclient_py" \
    runhooks
}

run_legacy_configure_and_build() {
  local version_name="$1"
  local build_kind="$2"
  local source_head="$3"

  local workspace="$BUILD_ROOT/$version_name/legacy-workspace"
  local source_dir="$workspace/src"
  local legacy_tools_dir="$BUILD_ROOT/.legacy-tools/depot_tools"
  local gclient_py="$legacy_tools_dir/gclient.py"
  local legacy_path="$legacy_tools_dir:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  ensure_legacy_depot_tools "$legacy_tools_dir"
  prepare_legacy_source "$source_dir" "$source_head"

  /bin/mkdir -p "$BUILD_DIR"
  install_legacy_python_shim "$BUILD_DIR/tool-shim/python3"

  if [[ ! -f "$workspace/.gclient" ]]; then
    run_in_legacy_workspace "$workspace" \
      /usr/bin/env \
      DEPOT_TOOLS_UPDATE=0 \
      DEPOT_TOOLS_COLLECT_METRICS=0 \
      DEPOT_TOOLS_METRICS=0 \
      PATH="$legacy_path" \
      "$PYTHON_BIN_LEGACY" \
      "$gclient_py" \
      config \
      "$REPO_ROOT" \
      --name=src \
      --unmanaged
  fi

  run_in_legacy_workspace "$workspace" \
    /usr/bin/env \
    DEPOT_TOOLS_UPDATE=0 \
    DEPOT_TOOLS_COLLECT_METRICS=0 \
    DEPOT_TOOLS_METRICS=0 \
    PATH="$legacy_path" \
    "$PYTHON_BIN_LEGACY" \
    "$gclient_py" \
    sync \
    --nohooks \
    --no-history \
    -j "$JOBS"
  patch_legacy_gyp_clt_detection \
    "$source_dir/packager/tools/gyp/pylib/gyp/xcode_emulation.py"
  run_legacy_runhooks "$workspace" "$BUILD_DIR" "${build_kind}" "$gclient_py"
  run_clean_env "$NINJA_BIN" -C "$BUILD_DIR/Release" -j "$JOBS" packager

  PACKAGER_BIN="$BUILD_DIR/Release/packager"
  if (( BUILD_SHARED )); then
    LIBPACKAGER_DYLIB="$BUILD_DIR/Release/libpackager.dylib"
  else
    LIBPACKAGER_DYLIB=""
  fi
}

if [[ "$BUILD_BACKEND" == "modern" ]]; then
  run_clean_env "$CMAKE_BIN" --version >/dev/null
  "$NINJA_BIN" --version >/dev/null
  "$GIT_BIN" --version >/dev/null
  "$PYTHON_BIN_MODERN" --version >/dev/null
else
  "$NINJA_BIN" --version >/dev/null
  "$GIT_BIN" --version >/dev/null
fi

if [[ "$BUILD_BACKEND" == "modern" ]]; then
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
fi

if (( BUILD_SHARED )); then
  BUILD_KIND="shared"
else
  BUILD_KIND="static"
fi

if [[ "$BUILD_BACKEND" == "modern" ]]; then
  run_clean_env "$GIT_BIN" -C "$REPO_ROOT" submodule sync --recursive
  run_clean_env "$GIT_BIN" -C "$REPO_ROOT" submodule update --force --recursive --init
fi

if [[ "$BUILD_BACKEND" == "modern" ]]; then
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

  CMFLAGS='-Wc++14-compat -Wno-c++14-compat -Wc++17-compat -Wno-c++17-compat -Wc++20-compat -Wno-c++20-compat'

  BUILD_DIR="$BUILD_ROOT/$VERSION_NAME/$BUILD_KIND"
  DIST_DIR="$DIST_ROOT/$VERSION_NAME"
  VERSION_DIR="$DIST_DIR"

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
    -DPython3_EXECUTABLE="$PYTHON_BIN_MODERN" \
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
  if (( BUILD_SHARED )); then
    LIBPACKAGER_DYLIB="$BUILD_DIR/packager/libpackager.dylib"
  else
    LIBPACKAGER_DYLIB=""
  fi
else
  BUILD_DIR="$BUILD_ROOT/$VERSION_NAME/$BUILD_KIND"
  DIST_DIR="$DIST_ROOT/$VERSION_NAME"
  VERSION_DIR="$DIST_DIR"
  run_legacy_configure_and_build "$VERSION_NAME" "$BUILD_KIND" "$("$GIT_BIN" -C "$REPO_ROOT" rev-parse HEAD)"
fi

if [[ ! -x "$PACKAGER_BIN" ]]; then
  die "Expected binary not found: $PACKAGER_BIN"
fi
if (( BUILD_SHARED )) && [[ ! -f "$LIBPACKAGER_DYLIB" ]]; then
  die "Expected shared library missing: $LIBPACKAGER_DYLIB"
fi

if [[ ! -d "$DIST_ROOT" ]]; then
  /bin/mkdir -p "$DIST_ROOT"
fi

STAGE_TMP_DIR="$(
  /usr/bin/mktemp -d "${DIST_ROOT}/.packager-stage.XXXXXX"
)"
STAGE_VERSION_DIR="$STAGE_TMP_DIR/$VERSION_NAME"
/bin/mkdir -p "$STAGE_VERSION_DIR"

/bin/cp "$PACKAGER_BIN" "$STAGE_VERSION_DIR/packager"
/bin/chmod +x "$STAGE_VERSION_DIR/packager"

if (( BUILD_SHARED )); then
  /bin/mkdir -p "$STAGE_VERSION_DIR/lib"
  /bin/cp "$LIBPACKAGER_DYLIB" "$STAGE_VERSION_DIR/lib/libpackager.dylib"

  if [[ "$BUILD_BACKEND" == "legacy" ]]; then
    adjust_legacy_shared_stage_artifacts "$STAGE_VERSION_DIR/packager" "$STAGE_VERSION_DIR/lib/libpackager.dylib"
  fi
fi

validate_staged_artifacts "$STAGE_VERSION_DIR"

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
