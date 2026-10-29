#!/usr/bin/env bash
# Runs the python unittest modules under bin/tests (later tasks append modules).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
cd "$(dirname "$0")" || exit 1
python3 -m unittest -v brain_scope_test brain_search_test brain_migrate_test brain_sweep_test
exit $?
