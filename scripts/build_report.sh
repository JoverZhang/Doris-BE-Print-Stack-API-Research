#!/usr/bin/env bash
set -euo pipefail

out=REPORT.md
{
  echo "# Stacktrace Research Report"
  echo
  echo "Generated: $(date -Is)"
  echo
  echo "## Case Reports"
  find . -path './.git' -prune -o -name report.md -print | sort | while read -r report; do
    echo
    echo "### ${report#./}"
    echo
    sed -n '1,120p' "$report"
  done
} > "$out"

echo "wrote $out"

