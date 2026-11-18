#!/usr/bin/env bash
# Tests the number of audit checks that scripts/gen-data.sh writes into README.md and the wiki
# (DOC_COUNTS, issue #225), on a copy of the files it reads in a temp folder. The copy passes --check.
# A sentence with another number makes --check fail and name its file and line, and a run puts the
# number back and changes nothing else. The same number in other text, or in a file the entry is not
# for, stays as it is. A reworded sentence or a missing file makes --check and a run fail and say so,
# and the run then writes nothing. No root, no network, and nothing in the repository changes.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# gen-data.sh needs jq. CI has it; on a machine without it, skip instead of failing the whole suite.
if ! command -v jq >/dev/null 2>&1; then
    printf 'ok: skip gen-data.sh audit check count tests (jq missing)\n'
    exit 0
fi

# Stop before any path is built if mktemp fails: an empty $tmp would copy the files to /.
if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the copy\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

fail=0
ok() { printf 'ok: %s\n' "$*"; }
bad() { printf 'not ok: %s\n' "$*"; fail=1; }

# The entries under test are the script's own, so a new entry is tested too.
DOC_COUNTS=()
eval "$(sed -n '/^DOC_COUNTS=(/,/^)/p' "$SCRIPT_DIR/scripts/gen-data.sh")"
if [[ ${#DOC_COUNTS[@]} -eq 0 ]]; then
    bad "no DOC_COUNTS=( ... ) list in scripts/gen-data.sh"
    exit 1
fi
doc_files=()
for entry in "${DOC_COUNTS[@]}"; do
    f="${entry%%|*}"
    [[ " ${doc_files[*]} " == *" $f "* ]] || doc_files+=("$f")
done

# A copy of what gen-data.sh reads and writes: it finds its files from its own path.
repo="$tmp/repo"
files=(scripts/gen-data.sh server-prep.sh server-audit.sh server-preconfig.sh server-prep.conf.example README.md
    site/data.json site/data.js "${doc_files[@]}")
for f in "${files[@]}"; do
    mkdir -p "$repo/$(dirname "$f")"
    cp "$SCRIPT_DIR/$f" "$repo/$f" || { bad "cannot copy $f"; exit 1; }
done

gen() {   # gen [--check]: runs the copy's gen-data.sh, output in $out, exit status in $rc
    out="$(bash "$repo/scripts/gen-data.sh" "$@" 2>&1)"
    rc=$?
}
replace_once() {   # replace_once FILE OLD NEW: the first OLD (plain text) in FILE becomes NEW
    OLD="$2" NEW="$3" awk 'BEGIN { o = ENVIRON["OLD"]; n = ENVIRON["NEW"] }
        !done && (i = index($0, o)) > 0 { $0 = substr($0, 1, i - 1) n substr($0, i + length(o)); done = 1 }
        { print }' "$1" > "$1.new" && mv "$1.new" "$1"
}
save() { rm -rf "$tmp/saved"; cp -R "$repo" "$tmp/saved"; }
same_as_saved() {   # same_as_saved LABEL: every file of the copy is as save() left it
    local d
    if d="$(diff -r "$tmp/saved" "$repo" 2>&1)"; then
        ok "$1"
    else
        bad "$1"
        printf '%s\n' "$d" | head -20
    fi
}

# 1. The copy, brought up to date first, so this test does not depend on the committed data
#    (the data section of scripts/check.sh checks that).
gen
if [[ $rc -ne 0 ]]; then
    bad "gen-data.sh on the copy exits $rc: $out"
    exit 1
fi
checks="$(jq '.audit.checks' "$repo/site/data.json")"
wrong=7
[[ $checks -ne $wrong ]] || wrong=8
save
gen --check
if [[ $rc -eq 0 && -z $out ]]; then
    ok "--check passes in silence when every sentence says $checks checks"
else
    bad "--check on an up-to-date copy: exit $rc, output: $out"
fi
# One line per entry: an entry whose texts also match another line of its file is too loose.
for entry in "${DOC_COUNTS[@]}"; do
    IFS='|' read -r f before after <<<"$entry"
    n="$(grep -cF -- "$before$checks$after" "$repo/$f")"
    if [[ $n -eq 1 ]]; then
        ok "\"$before<number>$after\" is on one line of $f"
    else
        bad "\"$before<number>$after\" is on $n lines of $f, want 1: make the entry's texts longer"
    fi
done

# 2. Each sentence in turn with another number.
for entry in "${DOC_COUNTS[@]}"; do
    IFS='|' read -r f before after <<<"$entry"
    replace_once "$repo/$f" "$before$checks$after" "$before$wrong$after"
    line="$(grep -nF -- "$before$wrong$after" "$repo/$f" | head -1 | cut -d: -f1)"
    if [[ -z $line ]]; then
        bad "$f has no \"$before$checks$after\" to change"
        continue
    fi
    gen --check
    want="$f:$line: says $wrong audit checks, server-audit.sh has $checks"
    if [[ $rc -eq 1 && $out == *"$want"* ]]; then
        ok "--check fails on \"$before$wrong$after\" and names $f:$line"
    else
        bad "--check on \"$before$wrong$after\" in $f: exit $rc, want 1 and \"$want\"; output: $out"
    fi
    gen
    if [[ $rc -eq 0 && $out == *"updated $f:$line: $wrong -> $checks audit checks"* ]]; then
        ok "a run puts $checks back in $f:$line"
    else
        bad "a run on \"$before$wrong$after\" in $f: exit $rc, output: $out"
    fi
    same_as_saved "the run changed only that number in $f"
done

# 3. Every sentence wrong at once: --check names each one.
for entry in "${DOC_COUNTS[@]}"; do
    IFS='|' read -r f before after <<<"$entry"
    replace_once "$repo/$f" "$before$checks$after" "$before$wrong$after"
done
gen --check
n="$(grep -c ": says $wrong audit checks" <<<"$out")"
if [[ $rc -eq 1 && $n -eq ${#DOC_COUNTS[@]} ]]; then
    ok "--check names all ${#DOC_COUNTS[@]} sentences when each holds another number"
else
    bad "--check with every sentence wrong: exit $rc, $n sentences named, want ${#DOC_COUNTS[@]}; output: $out"
fi
gen
same_as_saved "a run puts every number back"

# 4. Other numbers stay: a sentence's text in a file its entry is not for, the start of a sentence
#    with other words after the number, and a number with no sentence around it.
first="${doc_files[0]}"
for entry in "${DOC_COUNTS[@]}"; do
    IFS='|' read -r f before after <<<"$entry"
    if [[ $f != "$first" ]]; then
        printf '\n%s%s%s (not this file'\''s sentence)\n' "$before" "$wrong" "$after" >> "$repo/$first"
    fi
    printf '\n%s%s other words\n' "$before" "$wrong" >> "$repo/$f"
done
printf '\nA list of %s checks.\n' "$wrong" >> "$repo/$first"
save
gen --check
if [[ $rc -eq 0 ]]; then
    ok "--check passes with $wrong in text that is not one of the sentences"
else
    bad "--check with $wrong in other text: exit $rc, want 0; output: $out"
fi
gen
same_as_saved "a run leaves the other numbers as they are"

# 5. A reworded sentence: --check and a run fail and say so, and the run writes nothing.
IFS='|' read -r f before after <<<"${DOC_COUNTS[0]}"
replace_once "$repo/$f" "$before$checks$after" "Reworded: $checks$after"
gen --check
if [[ $rc -eq 1 && $out == *"$f: no line holds \"$before<number>$after\""* ]]; then
    ok "--check fails and names $f when its sentence is reworded"
else
    bad "--check with a reworded sentence in $f: exit $rc, want 1 and \"no line holds\"; output: $out"
fi
printf ' ' >> "$repo/site/data.json"   # out of date: a run that writes would fix it
save
gen
if [[ $rc -eq 1 && $out == *"$f: no line holds"* ]]; then
    ok "a run fails too when the sentence is reworded"
else
    bad "a run with a reworded sentence in $f: exit $rc, want 1; output: $out"
fi
same_as_saved "the failed run wrote nothing"

# 6. A missing file: the last one, since gen-data.sh also reads README.md for the site data.
f="${doc_files[-1]}"
rm "$repo/$f"
gen --check
if [[ $rc -eq 1 && $out == *"$f is missing"* ]]; then
    ok "--check fails and names $f when it is missing"
else
    bad "--check without $f: exit $rc, want 1 and \"$f is missing\"; output: $out"
fi

exit "$fail"
