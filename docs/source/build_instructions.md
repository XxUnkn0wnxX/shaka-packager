# Build Instructions

Shaka Packager supports building on Windows, Mac and Linux host systems.

## Linux build dependencies

Most development is done on Ubuntu (currently 22.04 LTS, Jammy Jellyfish).  The
dependencies mentioned here are only for Ubuntu. There are some instructions
for [other distros below](#notes-for-other-linux-distros).

```shell
sudo apt-get update
sudo apt-get install -y \
        curl \
        build-essential cmake git ninja-build python3
```

Note that `git` must be v1.7.6 or above to support relative paths in submodules.

Note also that `cmake` must be v3.24 or above to support a linker setting
needed for `absl::log_flags`.

## Mac system requirements

 * [Xcode](https://developer.apple.com/xcode) 7.3+.
 * The OS X 10.10 SDK or later. Run

   ```shell
   ls `xcode-select -p`/Platforms/MacOSX.platform/Developer/SDKs
   ```

   to check whether you have it.

## Install Ninja (recommended) using Homebrew

```shell
brew install ninja
```

## Windows system requirements

* Visual Studio 2017 or newer.
* Windows 10 or newer.

Recommended version of Visual Studio is 2022, the Community edition
should work for open source development of tools like Shaka Packager
but please check the Community license terms for your specific
situation.

Install the "Desktop development with C++" workload which will install
CMake and other needed tools.

If you use chocolatey, you can install these dependencies with:

```ps1
choco install -y `
  git cmake ninja python `
  visualstudio2022community visualstudio2022-workload-nativedesktop `
  visualstudio2022buildtools windows-sdk-10.0

# Find python install
$pythonpath = Get-Item c:\Python* | sort CreationDate | Select-Object -First 1

# Symlink python3 to python
New-Item -ItemType SymbolicLink `
  -Path "$pythonpath/python3.exe" -Target "$pythonpath/python.exe"

# Update global PATH
$env:PATH += ";C:\Program Files\Git\bin;c:\Program Files\CMake\bin;$pythonpath"
setx PATH "$env:PATH"
```

## Get the code

Dependencies are now managed via git submodules. To get a complete
checkout you can run:

```shell
git clone --recurse-submodules https://github.com/shaka-project/shaka-packager.git
```

### Build Shaka Packager

#### Linux and Mac

Shaka Packager uses [CMake](https://cmake.org) as the main build tool,
with Ninja as the recommended generator (outside of Windows).


```shell
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
```

If you want to build debug code, replace `Release` above with `Debug`.

You can change other build settings with `-D` flags to CMake, for example
you can build a shared `libpackager` instead of static by adding

```shell
-DBUILD_SHARED_LIBS="ON"
```

After configuring CMake you can run the build with

```shell
cmake --build build --parallel
```

To build portable, fully-static executables on Linux, you will need either musl
as your system libc, or a musl toolchain.  (See [musl.cc](https://musl.cc).
To create a portable, fully-static build for Linux, configure CMake with:

```shell
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS="OFF" \
  -DFULLY_STATIC="ON" \
  -DCMAKE_C_COMPILER=/path/to/x86_64-linux-musl-gcc \
  -DCMAKE_CXX_COMPILER=/path/to/x86_64-linux-musl-g++
```

#### Older Intel macOS compatibility helper

This fork includes [`build-local.zsh`](../../build-local.zsh), a macOS-only
helper intended for older Intel macOS systems, particularly macOS Big Sur with
Apple Clang 13 and Intel Homebrew under `/usr/local`. It is not the general
cross-platform build entry point and is not intended for Linux, Windows, or
Apple Silicon Homebrew installations under `/opt/homebrew`.

The helper keeps the normal vendored-dependency build but works around issues
seen with this older toolchain:

- Apple Clang implicitly finding Homebrew Abseil headers in
  `/usr/local/include` instead of using only the vendored Abseil sources. The
  script temporarily unlinks Homebrew Abseil and restores it on normal exit or
  interruption.
- C++14, C++17, and C++20 compatibility diagnostics being promoted to errors
  while compiling valid C++17 Abseil and generated protobuf code.
- Environment variables and Homebrew paths from unrelated local builds leaking
  into CMake dependency discovery.
- Legacy GYP releases parsing Xcode Command Line Tools versions as a
  single-digit major version. The compatibility change for CLT 13 is applied
  only to the disposable dependency checkout under `builder/`.

The build backend is detected from the checked-out source; there is no legacy
option to select manually:

- CMake-era versions synchronize the branch's recorded Git submodules, then
  configure CMake and build with Ninja. This path pins `/usr/local/bin/cmake`,
  `/usr/local/bin/ninja`, `/usr/local/bin/python3`, the Apple command-line
  compilers, and a macOS 11.0 deployment target.
- Older GYP-era versions synchronize the revisions in `DEPS` inside an isolated
  source checkout under `builder/`, always run the GYP configuration hooks, and
  then build with Ninja. A compatible depot_tools revision is downloaded into
  `builder/.legacy-tools/` on the first legacy run, so depot_tools does not need
  to be installed globally. This path uses Apple's `/usr/bin/python3` instead
  of a newer Homebrew Python.

Both paths use the dependencies recorded by the checked-out Shaka source, so
they do not require reinstalling system copies of libxml2, protobuf, Abseil, or
similar libraries. A legacy build needs network access the first time it fetches
depot_tools and the `DEPS` repositories.

From the repository root, run:

```shell
# Configure, then build the default static Packager executable.
./build-local.zsh

# Remove modern and legacy temporary build/dependency directories first, then
# configure/build. Existing dist artifacts are retained until publish succeeds.
./build-local.zsh --clean

# Build Packager plus libpackager.dylib using the current backend's shared mode.
./build-local.zsh --libs

# Combine the explicit cleanup and shared-library modes.
./build-local.zsh --clean --libs
```

Builds use eight parallel jobs by default. Override that when needed with, for
example:

```shell
SHAKA_JOBS=4 ./build-local.zsh
```

The source-controlled `.release-please-manifest.json` file determines the output
version via its `"."` value. For older source trees without that manifest, the
helper reads the first strict `X.Y.Z` release heading in `CHANGELOG.md`. It never
uses Git tags to choose the output version. A source version of `3.9.3` therefore
publishes under `dist/3.9.3/`, while `2.6.1` publishes under `dist/2.6.1/`.
Static mode publishes only the `packager` executable. With `--libs`, the version
directory also contains `lib/libpackager.dylib`; third-party dependencies remain
static. Legacy shared builds are relocated only in the staged copy so this same
two-file layout remains runnable.

Static and shared builds use separate temporary trees under
`builder/<version>/`; legacy versions share one isolated dependency checkout
between those two output trees. The script always refreshes the applicable
dependency metadata and configures before it builds. Cleanup occurs only when
`--clean` is explicitly supplied. It removes the script-managed `builder/`
tree—including that disposable legacy checkout—and old root `out/` GYP output,
but never removes the real Git checkout or `dist`. After a successful build,
artifacts are staged and checked before only the matching `dist/<version>`
directory is replaced.

#### Windows

Windows build instructions are similar. Using Tools > Command Line >
Developer Command Prompt should open a terminal with cmake and ctest in the
PATH.  Omit the `-G Ninja` to use the default backend, and pass `--config`
during build to select the desired configuration from Visual Studio.

```shell
cmake -B build
cmake --build build --parallel --config Release
```

### Build artifacts

After a successful build, you can find build artifacts including the main
`packager` binary in build output directory (`build/packager/` for a Ninja
build, `build/packager/Release/` for a Visual Studio release build, or
`build/packager/Debug/` for a Visual Studio debug build).

See [Shaka Packager Documentation](https://shaka-project.github.io/shaka-packager/html/)
on how to use `Shaka Packager`.

### Installation

To install Shaka Packager, run:

```shell
cmake --install build/ --strip --config Release
```

You can customize the output location with `--prefix` (default `/usr/local` on
Linux and macOS) and the `DESTDIR` environment variable.  These are provided by
CMake and follow standard conventions for installation.  For example, to build
a package by installing to `foo` instead of the system root, and to use `/usr`
instead of `/usr/local`, you could run:

```shell
DESTDIR=foo cmake --install build/ --strip --config Release --prefix=/usr
```

### Update your checkout

To update an existing checkout, you can run

```shell
git pull origin main --rebase
git submodule update --init --recursive
```

The first command updates the primary Packager source repository and rebases on
top of tip-of-tree (aka the Git branch `origin/main`). You can also use other
common Git commands to update the repo.

The second updates submodules for third-party dependencies.

## Notes for other linux distros

The docker files at `packager/testing/dockers` have the most up to
date commands for installing dependencies. For example:

### Alpine Linux

Use `apk` command to install dependencies:

```shell
apk add --no-cache \
        bash curl \
        bsd-compat-headers linux-headers \
        build-base cmake git ninja python3
```

### Arch Linux

Instead of running `sudo apt-get install` to install build dependencies, run:

```shell
pacman -Suy --needed --noconfirm \
        core/which \
        cmake gcc git ninja python3
```

### Debian

Same as Ubuntu.

```shell
apt-get install -y \
        curl \
        build-essential cmake git ninja-build python3
```

### Fedora

Instead of running `sudo apt-get install` to install build dependencies, run:

```shell
yum install -y \
        which \
        libatomic \
        cmake gcc-c++ git ninja-build python3
```

### CentOS

For CentOS, Ninja is only available from the CRB (Code Ready Builder) repo

```shell
dnf update -y
dnf install -y yum-utils
dnf config-manager --set-enabled crb
```

then same as Fedora

```shell
yum install -y \
        which \
        libatomic \
        cmake gcc-c++ git ninja-build python3
```

### OpenSUSE

Use `zypper` command to install dependencies:

```shell
zypper in -y \
        curl which \
        cmake gcc9-c++ git ninja python3
```

OpenSuse 15 doesn't have the required gcc 9+ by default, but we can install
it as gcc9 and symlink it.

```shell
ln -s g++-9 /usr/bin/g++
ln -s gcc-9 /usr/bin/gcc
```

## Tips, tricks, and troubleshooting

### Xcode license agreement

If you are getting the error

> Agreeing to the Xcode/iOS license requires admin privileges, please re-run as
> root via sudo.

the Xcode license has not been accepted yet which (contrary to the message) any
user can do by running:

```shell
xcodebuild -license
```

Only accepting for all users of the machine requires root:

```shell
sudo xcodebuild -license
```

### Using an IDE

No specific instructions are available. However most IDEs with CMake
support should work out of the box

## Contributing

If you have improvements or fixes, we would love to have your contributions.
See https://github.com/shaka-project/shaka-packager/blob/main/CONTRIBUTING.md for
details.

We have continue integration tests setup on pull requests. You can also verify
locally by running the tests manually.

```shell
ctest -C Debug -V --test-dir build
```

You can find out more about GoogleTest at its
[GitHub page](https://github.com/google/googletest).

You should install `clang-format` (using `apt install` or `brew
install` depending on platform) to ensure that all code changes are
properly formatted.

You should commit or stage (with `git add`) any code changes first. Then run

```shell
git clang-format --style Chromium origin/main
```

This will run formatting over just the files you modified (any changes
since origin/main).
