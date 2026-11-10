#!/usr/bin/env bash
# Checks .github/labels.yml, the label taxonomy (issue #24): every label has a name, a color of 6 hex
# digits and a description, each a double-quoted string; no two names match ignoring case; and the
# five labels the release notes use are there. Then it runs the same check on broken copies built in
# a temp folder. When mikefarah yq and jq are installed (GitHub-hosted runners have both), it also
# checks that yq reads the same labels. It does not compare the file with the labels on GitHub.
# No root, no network, and nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABELS="$SCRIPT_DIR/.github/labels.yml"
# .github/release.yml sorts the release notes by these. .github/dependabot.yml also sets
# skip-changelog.
RELEASE_LABELS=(security enhancement bug documentation skip-changelog)
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

end_label() {   # end_label: checks the label parse_labels has just read (its locals) and prints it as name TAB color TAB description
    local bad=0
    if (( ncolor != 1 )); then
        printf 'not ok: label "%s": %d color lines, want 1\n' "$name" "$ncolor"
        bad=1
    elif [[ ! "$color" =~ ^[0-9A-Fa-f]{6}$ ]]; then
        printf 'not ok: label "%s": color "%s" is not 6 hex digits (no #)\n' "$name" "$color"
        bad=1
    fi
    if (( ndesc != 1 )); then
        printf 'not ok: label "%s": %d description lines, want 1\n' "$name" "$ndesc"
        bad=1
    elif [[ -z "$desc" ]]; then
        printf 'not ok: label "%s": empty description\n' "$name"
        bad=1
    fi
    (( bad )) || printf '%s\t%s\t%s\n' "$name" "$color" "$desc" >&3
    return "$bad"
}

parse_labels() {   # parse_labels FILE: prints each valid label on fd 3 and each problem on stdout; returns 1 on any problem
    # Stricter than YAML on purpose: only blank lines, comments and the three keys, each value in
    # double quotes with no " or \ inside, so this reads exactly what YAML reads.
    local file="$1" line lineno=0 bad=0 key value open=0
    local name="" color="" desc="" ncolor=0 ndesc=0
    local re='^(- name|  color|  description): "([^"\\]*)"$'
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        [[ -z "$line" || "$line" == '#'* ]] && continue
        if [[ ! "$line" =~ $re ]]; then
            printf 'not ok: line %d: want a comment, a blank line, - name, color or description with a value in double quotes (no " or \\ inside): %s\n' \
                "$lineno" "$line"
            bad=1
            continue
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [[ "$value" == *$'\t'* || "$value" == ' '* || "$value" == *' ' ]]; then
            printf 'not ok: line %d: the value holds a tab or starts or ends with a space: %s\n' "$lineno" "$line"
            bad=1
            continue
        fi
        if [[ "$key" == '- name' ]]; then
            if (( open )); then end_label || bad=1; fi
            open=1 name="$value" color="" desc="" ncolor=0 ndesc=0
            if [[ -z "$name" ]]; then
                printf 'not ok: line %d: empty name\n' "$lineno"
                bad=1
            fi
        elif (( ! open )); then
            printf 'not ok: line %d: %s before the first - name\n' "$lineno" "${key#  }"
            bad=1
        elif [[ "$key" == '  color' ]]; then
            color="$value" ncolor=$((ncolor + 1))
        else
            desc="$value" ndesc=$((ndesc + 1))
        fi
    done < "$file"
    if (( open )); then end_label || bad=1; fi
    return "$bad"
}

check_labels() {   # check_labels FILE: prints each problem; returns 1 on any
    local file="$1" bad=0 parsed names dups dup l json read_by_yq
    [[ -f "$file" ]] || { printf 'not ok: %s not found\n' "$file"; return 1; }
    # The labels go to fd 3, captured in a file; the problems go straight to stdout.
    parse_labels "$file" 3>"$tmp/parsed" || bad=1
    parsed="$(cat "$tmp/parsed")"
    if [[ -z "$parsed" ]]; then
        printf 'not ok: no valid label in the file\n'
        return 1
    fi
    names="$(cut -f1 <<<"$parsed")"
    dups="$(tr '[:upper:]' '[:lower:]' <<<"$names" | sort | uniq -d)"
    if [[ -n "$dups" ]]; then
        while IFS= read -r dup; do
            printf 'not ok: two labels are named "%s" ignoring case\n' "$dup"
        done <<<"$dups"
        bad=1
    fi
    for l in "${RELEASE_LABELS[@]}"; do
        if ! grep -qxF -- "$l" <<<"$names"; then
            printf 'not ok: label "%s" is missing: the release notes use it, never rename or remove it\n' "$l"
            bad=1
        fi
    done
    # A second reader when one is there: what yq reads must be what this check read.
    if (( ! bad )) && command -v jq >/dev/null && command -v yq >/dev/null \
        && yq --version 2>&1 | grep -q mikefarah; then
        if ! json="$(yq -o=json '.' "$file" 2>&1)"; then
            printf 'not ok: yq cannot read the file: %s\n' "$json"
            bad=1
        elif ! read_by_yq="$(jq -r 'if type == "array" and all(.[]; type == "object" and ((keys - ["color", "description", "name"]) | length) == 0)
                then .[] | [.name, .color, .description] | map(tostring) | @tsv
                else error("not a list of name, color and description maps") end' <<<"$json" 2>&1)"; then
            printf 'not ok: yq reads something else than a list of labels: %s\n' "$read_by_yq"
            bad=1
        elif [[ "$read_by_yq" != "$parsed" ]]; then
            printf 'not ok: yq reads other labels than this check:\n'
            diff <(printf '%s\n' "$parsed") <(printf '%s\n' "$read_by_yq")
            bad=1
        fi
    fi
    return "$bad"
}

# The repo itself
if ! check_labels "$LABELS"; then
    printf 'not ok: .github/labels.yml has problems (see above)\n'
    exit 1
fi
printf 'ok: .github/labels.yml: %d labels, all valid, no duplicate, release-notes labels there\n' \
    "$(grep -c '^- name: ' "$LABELS")"

# The check on broken copies
expect_broken() {   # expect_broken WHAT FILE WANT: check_labels must fail on FILE and say WANT
    local out
    if out="$(check_labels "$2" 2>&1)"; then
        printf 'not ok: %s passes, want a failure\n' "$1"
        exit 1
    fi
    if [[ "$out" != *"$3"* ]]; then
        printf 'not ok: %s fails without saying "%s":\n%s\n' "$1" "$3" "$out"
        exit 1
    fi
    printf 'ok: %s fails\n' "$1"
}

drop_label() {   # drop_label NAME OUT: the repo file without label NAME
    awk -v n="- name: \"$1\"" '
        $0 == n { skip = 1; next }
        /^- name: / || /^$/ || /^#/ { skip = 0 }
        !skip' "$LABELS" > "$2"
}

edit_label() {   # edit_label NAME KEY LINE OUT: the repo file with the KEY line of label NAME replaced by LINE ("" drops it)
    awk -v n="- name: \"$1\"" -v k="  $2:" -v r="$3" '
        /^- name: / { in_label = ($0 == n) }
        in_label && index($0, k) == 1 { if (r != "") print r; next }
        { print }' "$LABELS" > "$4"
}

for l in "${RELEASE_LABELS[@]}"; do
    drop_label "$l" "$tmp/no-$l.yml"
    expect_broken "a file without $l" "$tmp/no-$l.yml" "label \"$l\" is missing"
done

{ cat "$LABELS"; printf '%s\n' '- name: "Bug"' '  color: "d73a4a"' '  description: "Same name, other case"'; } > "$tmp/dup.yml"
expect_broken 'a file with two names that match ignoring case' "$tmp/dup.yml" 'two labels are named "bug" ignoring case'

edit_label bug color '  color: "#d73a4a"' "$tmp/hash.yml"
expect_broken 'a color with #' "$tmp/hash.yml" 'color "#d73a4a" is not 6 hex digits'

edit_label bug color '  color: "d73a4"' "$tmp/short.yml"
expect_broken 'a color of 5 digits' "$tmp/short.yml" 'color "d73a4" is not 6 hex digits'

edit_label bug color '' "$tmp/no-color.yml"
expect_broken 'a label without color' "$tmp/no-color.yml" 'label "bug": 0 color lines, want 1'

edit_label bug description '  description: ""' "$tmp/empty-desc.yml"
expect_broken 'an empty description' "$tmp/empty-desc.yml" 'label "bug": empty description'

edit_label bug description '' "$tmp/no-desc.yml"
expect_broken 'a label without description' "$tmp/no-desc.yml" 'label "bug": 0 description lines, want 1'

edit_label bug color '  color: d73a4a' "$tmp/unquoted.yml"
expect_broken 'an unquoted color' "$tmp/unquoted.yml" 'want a comment, a blank line'

sed 's/^- name: "area: audit"$/- name: area: audit/' "$LABELS" > "$tmp/unquoted-name.yml"
expect_broken 'an unquoted name with ": "' "$tmp/unquoted-name.yml" 'want a comment, a blank line'

sed 's/^- name: "bug"$/- name: ""/' "$LABELS" > "$tmp/empty-name.yml"
expect_broken 'an empty name' "$tmp/empty-name.yml" 'empty name'

printf 'ok: the labels check passes on .github/labels.yml and fails on every broken copy\n'
