#!/bin/bash
# workerd's Python Workers tests against the WASI Python Worker; see run.mjs.
#   compat-tests/run.sh [test-name...]
cd "$(dirname "$0")" && exec node run.mjs "$@"
