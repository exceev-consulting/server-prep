#!/usr/bin/env bash
# Builds the GitHub Pages site the way pages.yml does, from local results, to look at it before
# pushing: the setup console at /, the list of reports at /e2e/, and the results of
# tests/e2e/run.sh as the main report at /e2e/main/.
#
#   tests/e2e/preview.sh [--out DIR] [RESULT_DIR...]
#   python3 -m http.server --bind 127.0.0.1 --directory tests/e2e/out/site 8765
#
# RESULT_DIR defaults to every tests/e2e/out/<os>/ that has a results.json. DIR defaults to
# tests/e2e/out/site (ignored by git) and is rebuilt from scratch.
set -u

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$E2E_DIR/../.." && pwd)"
OUT="$E2E_DIR/out/site"
DIRS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --out) [[ $# -ge 2 ]] || { echo "--out needs a value" >&2; exit 2; }; OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
        *) DIRS+=("$1"); shift ;;
    esac
done
if [[ ${#DIRS[@]} -eq 0 ]]; then
    for f in "$E2E_DIR"/out/*/results.json; do
        [[ -f "$f" ]] && DIRS+=("${f%/results.json}")
    done
fi
[[ ${#DIRS[@]} -gt 0 ]] || { echo "No results: run tests/e2e/run.sh --os <id> first" >&2; exit 1; }

rm -rf -- "$OUT" && mkdir -p -- "$OUT" || exit 1
cp -r "$REPO_DIR/site/." "$OUT/" || exit 1
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sha="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
branch="$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || true)"
title="Local run${branch:+ of $branch}"

bash "$E2E_DIR/build-report.sh" --out "$OUT/e2e/main" --meta source=local --meta "generated=$now" \
    --meta "sha=$sha" --meta "ref=$branch" "${DIRS[@]}" || exit 1
status="$(jq -r '.status' "$OUT/e2e/main/summary.json")"
jq -n --arg now "$now" --arg title "$title" --arg sha "$sha" --arg status "$status" \
    --slurpfile s "$OUT/e2e/main/summary.json" \
    '{schema: 1, generated: $now, reports: [{path: "main/", kind: "main", title: $title, sha: $sha,
      status: $status, run_url: "", date: $now}
      + ($s[0] | {counts, oses: [.oses[]? | {os, label, status, duration_s,
                                             audit_fail: (.audit_rebooted.fail? // null)}]})]}' > "$OUT/e2e/.index.json"
bash "$E2E_DIR/build-report.sh" --index --out "$OUT/e2e" "$OUT/e2e/.index.json" || exit 1
rm -f -- "$OUT/e2e/.index.json"
echo "preview: $OUT (setup console at /, reports at /e2e/)"
