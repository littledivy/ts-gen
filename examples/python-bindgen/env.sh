# Sourced by the build scripts: the cache directory, the host's wasi-sdk
# release name, the host Python and the job count.
#
# PYTHON_DEPS is where the toolchains, CPython and the package builds are
# cached (default deps/ beside this file). HOSTPY is a native Python 3.13
# for the build's own tooling (default python3.13 on PATH).
#
# PYTHON_DEPS is made physical: macOS cpio won't extract through a
# symlinked directory (such as /tmp), and the recipes copy with it.
PYTHON_DEPS=${PYTHON_DEPS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deps}
mkdir -p "$PYTHON_DEPS" && PYTHON_DEPS=$(cd "$PYTHON_DEPS" && pwd -P)
export PYTHON_DEPS
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) HOST=arm64-macos ;;
  Darwin-x86_64) HOST=x86_64-macos ;;
  Linux-aarch64 | Linux-arm64) HOST=arm64-linux ;;
  *) HOST=x86_64-linux ;;
esac
HOSTPY=${HOSTPY:-$(command -v python3.13 || true)}
[ -n "$HOSTPY" ] || { echo "python3.13 not found: set HOSTPY" >&2; exit 1; }
NCPU=${NCPU:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}
