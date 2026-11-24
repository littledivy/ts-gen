#!/bin/bash
# Runs workers-py's runtime-sdk tests (packages/runtime-sdk/tests) against the
# WASI Python Worker; adapter.py says how.
#
#   sdk-tests/run.sh [pytest args...]   # default: the whole suite
#
# WORKERS_PY is a checkout of github.com/cloudflare/workers-py (default
# sdk-tests/work/workers-py, cloned there if missing). The host side
# runs in sdk-tests/work/.venv with pytest, requests and pyodide-tblib, with
# testlib from the checkout.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${SDK_TESTS_WORK:-$HERE/work}
WORKERS_PY=${WORKERS_PY:-$WORK/workers-py}
[ -d "$WORKERS_PY" ] || git clone -q https://github.com/cloudflare/workers-py "$WORKERS_PY"
. "$HERE/../env.sh"
VENV=$WORK/.venv
if [ ! -x "$VENV/bin/python" ]; then
  "$HOSTPY" -m venv "$VENV"
  "$VENV/bin/pip" -q install --disable-pip-version-check pytest requests "pyodide-tblib>=3.2.3"
fi
SITEPK=$("$VENV/bin/python" -I -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
printf '%s\n%s\n' "$HERE" "$WORKERS_PY/packages/testlib" > "$SITEPK/cf-sdk-tests.pth"
export WORKERS_PY SDK_TESTS_WORK=$WORK
cd "$WORKERS_PY/packages/runtime-sdk"
# testlib forwards the command line's options to the in-worker pytest runs,
# but not these.
export PYTEST_ADDOPTS="-p adapter --basetemp $WORK/tmp -p no:cacheprovider --junitxml $WORK/results.xml -rfEs"
exec "$VENV/bin/python" -I -m pytest "${@:-tests}"
