#!/usr/bin/env bash
#
# Tests for dashboard.py — theme colour maths and contrast, render, the dashboards.md
# registry, and brain-monitor line → workers-collection writes. Runs offline (temp files
# only), python3 stdlib unittest over dashboard_test.py.

set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1  # keep __pycache__ out of the repo
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE" || exit 1
python3 -m unittest -v dashboard_test
exit $?
