#!/usr/bin/env bash
set -euo pipefail

out=REPORT.md
{
  echo "# Stacktrace Research Report"
  echo
  echo "Generated: $(date -Is)"
  echo
  if [[ -f matrix.csv ]]; then
    echo "## Matrix"
    echo
    echo '```csv'
    cat matrix.csv
    echo '```'
    echo
  fi
  if [[ -f reference_checklist/checklist.md ]]; then
    echo "## Reference Checklist"
    echo
    sed -n '1,220p' reference_checklist/checklist.md
    echo
  fi
  echo "## Case Reports"
  find . -path './.git' -prune -o -path './templates' -prune -o -name report.md -print | sort | while read -r report; do
    echo
    echo "### ${report#./}"
    echo
    cat "$report"
  done
} > "$out"

echo "wrote $out"
