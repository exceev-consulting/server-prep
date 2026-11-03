#!/usr/bin/env bash
# Checks that Claude Code and Codex see the same skills (issue #33): .agents/skills must be the
# relative link to .claude/skills, and every SKILL.md frontmatter must hold only a one-line `name`
# (its folder name) and a one-line `description`, each a value YAML reads as a non-empty string.
# Then it runs the same check on broken trees built in a temp folder. No root needed and nothing on
# the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

value_problem() {   # value_problem VALUE: prints why VALUE is not a one-line YAML string; nothing when it is
    # Stricter than YAML on purpose: a value that passes here reads as a non-empty string.
    local v="$1" q inner
    local start_re='^[][`{}@?:,&*!%#-]'
    # YAML drops the spaces around a value.
    v="${v#"${v%%[! ]*}"}"
    v="${v%"${v##*[! ]}"}"
    if [[ "$v" == *$'\t'* ]]; then
        # Parsers disagree on tabs inside or after a plain value.
        printf 'holds a tab'
    elif [[ -z "$v" ]]; then
        printf 'is empty'
    elif [[ "$v" == [\>\|]* ]]; then
        printf 'must be on one line, not a > or | block'
    elif [[ "$v" == [\"\']* ]]; then
        q="${v:0:1}"
        if (( ${#v} < 2 )) || [[ "${v: -1}" != "$q" ]]; then
            printf 'starts with %s but does not end with it' "$q"
            return
        fi
        inner="${v:1:${#v}-2}"
        if [[ -z "$inner" ]]; then
            printf 'is empty'
        elif [[ "$q" == \" && ( "$inner" == *\"* || "$inner" == *\\* ) ]]; then
            # A " ends the value early and a \ starts an escape: use single quotes instead.
            printf 'holds " or \\ inside double quotes (use single quotes)'
        elif [[ "$q" == \' && "${inner//\'\'/}" == *\'* ]]; then
            printf "holds a single ' inside single quotes (write it '')"
        fi
    elif [[ "$v" =~ $start_re ]]; then
        # A backtick and @ are reserved, % starts a directive, [ { & * ! give a list, a map, an
        # anchor, an alias or a tag instead of a string, and - ? : , ] } # can break the line.
        printf 'starts with "%s": quote it' "${v:0:1}"
    elif [[ "$v" == *: ]]; then
        printf 'ends with ":": quote it'
    elif [[ "$v" == *': '* || "$v" == *' #'* ]]; then
        printf 'holds ": " or " #": quote it'
    fi
}

check_frontmatter() {   # check_frontmatter FOLDER FILE: one "not ok" line per problem, returns 1 if any
    local folder="$1" file="$2" line="" n=1 closed=no name="" names=0 descs=0 bad=0 key value problem
    local re='^(name|description): (.+)$'
    {
        IFS= read -r line
        if [[ "$line" != --- ]]; then
            printf 'not ok: %s/SKILL.md: line 1 must be --- (the start of the frontmatter)\n' "$folder"
            return 1
        fi
        while IFS= read -r line || [[ -n "$line" ]]; do
            n=$((n + 1))
            if [[ "$line" == --- ]]; then
                closed=yes
                break
            fi
            # Only `name: value` and `description: value`, each on one line: no other key (such as
            # allowed-tools, which only Claude Code knows), no blank or indented line.
            if [[ ! "$line" =~ $re ]]; then
                printf 'not ok: %s/SKILL.md line %d: only one-line name and description are allowed: %s\n' \
                    "$folder" "$n" "$line"
                bad=1
                continue
            fi
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # A value YAML can't read, or reads as something other than a non-empty string (a block,
            # a list, a map, nothing): Codex then drops the skill.
            problem="$(value_problem "$value")"
            if [[ -n "$problem" ]]; then
                printf 'not ok: %s/SKILL.md line %d: the %s %s\n' "$folder" "$n" "$key" "$problem"
                bad=1
            fi
            if [[ "$key" == name ]]; then
                names=$((names + 1))
                name="$value"
            else
                descs=$((descs + 1))
                # The Agent Skills format caps the description at 1024 characters.
                if (( ${#value} > 1024 )); then
                    printf 'not ok: %s/SKILL.md: the description is longer than 1024 characters\n' "$folder"
                    bad=1
                fi
            fi
        done
    } < "$file"

    if [[ "$closed" != yes ]]; then
        printf 'not ok: %s/SKILL.md: no closing --- after the frontmatter\n' "$folder"
        bad=1
    fi
    if (( names != 1 )); then
        printf 'not ok: %s/SKILL.md: %d name lines, want 1\n' "$folder" "$names"
        bad=1
    elif [[ "$name" != "$folder" ]]; then
        printf 'not ok: %s/SKILL.md: name is "%s", want the folder name "%s"\n' "$folder" "$name" "$folder"
        bad=1
    elif [[ ! "$name" =~ ^[a-z0-9-]{1,64}$ ]]; then
        # Codex takes at most 64 characters; lower case, digits and dashes work in both agents.
        printf 'not ok: %s/SKILL.md: name must be 1-64 characters a-z, 0-9 or -\n' "$folder"
        bad=1
    fi
    if (( descs != 1 )); then
        printf 'not ok: %s/SKILL.md: %d description lines, want 1\n' "$folder" "$descs"
        bad=1
    fi
    return "$bad"
}

check_skills() {   # check_skills ROOT: .agents/skills links to .claude/skills, every SKILL.md is valid
    local root="$1" link="$1/.agents/skills" target dir folder found=0 bad=0
    # Plain readlink (no -f, which old macOS lacks) and -ef keep this portable.
    if [[ ! -L "$link" ]]; then
        printf 'not ok: .agents/skills is not a symlink (on Windows see Skills in AGENTS.md)\n'
        bad=1
    else
        target="$(readlink "$link")"
        if [[ "$target" != ../.claude/skills ]]; then
            printf 'not ok: .agents/skills links to %s, want ../.claude/skills\n' "$target"
            bad=1
        elif [[ ! "$link" -ef "$root/.claude/skills" ]]; then
            printf 'not ok: .agents/skills does not resolve to .claude/skills\n'
            bad=1
        fi
    fi
    for dir in "$root"/.claude/skills/*/; do
        [[ -d "$dir" ]] || continue
        dir="${dir%/}"
        folder="${dir##*/}"
        found=$((found + 1))
        if [[ ! -f "$dir/SKILL.md" ]]; then
            printf 'not ok: .claude/skills/%s has no SKILL.md\n' "$folder"
            bad=1
            continue
        fi
        check_frontmatter "$folder" "$dir/SKILL.md" || bad=1
    done
    if (( found == 0 )); then
        printf 'not ok: no skill found in .claude/skills\n'
        bad=1
    fi
    return "$bad"
}

# The repo itself
check_skills "$SCRIPT_DIR" || exit 1
printf 'ok: .agents/skills links to .claude/skills, every SKILL.md frontmatter is valid\n'

# The check on broken trees
fixture() {   # fixture NAME: a good tree under $tmp/NAME with one skill, demo; prints its root
    local root="$tmp/$1"
    mkdir -p "$root/.claude/skills/demo" "$root/.agents"
    printf '%s\n' --- 'name: demo' 'description: A demo skill.' --- '' '# Demo' > "$root/.claude/skills/demo/SKILL.md"
    ln -s ../.claude/skills "$root/.agents/skills"
    printf '%s\n' "$root"
}
skill_md() {   # skill_md ROOT LINE...: replace the demo SKILL.md with these lines
    local root="$1"
    shift
    printf '%s\n' "$@" > "$root/.claude/skills/demo/SKILL.md"
}
expect() {   # expect pass|fail LABEL ROOT
    local want="$1" label="$2" root="$3" got=fail
    check_skills "$root" >/dev/null && got=pass
    if [[ "$got" != "$want" ]]; then
        printf 'not ok: %s gives %s, want %s\n' "$label" "$got" "$want"
        check_skills "$root" >&2
        exit 1
    fi
    printf 'ok: %s gives %s\n' "$label" "$got"
}

root="$(fixture good)"
expect pass 'a good tree' "$root"

root="$(fixture quoted)"
skill_md "$root" --- 'name: demo' 'description: "Use when: the user asks # for a demo."' --- '' '# Demo'
expect pass 'a quoted description with ": " and " #"' "$root"

root="$(fixture no-link)"
rm "$root/.agents/skills"
expect fail '.agents/skills missing' "$root"

root="$(fixture copy)"
rm "$root/.agents/skills"
cp -R "$root/.claude/skills" "$root/.agents/skills"
expect fail 'a copy instead of the link' "$root"

root="$(fixture text-file)"
rm "$root/.agents/skills"
printf '%s' ../.claude/skills > "$root/.agents/skills"
expect fail 'a text file holding ../.claude/skills (Windows checkout)' "$root"

root="$(fixture other)"
rm "$root/.agents/skills"
cp -R "$root/.claude/skills" "$root/other"
ln -s ../other "$root/.agents/skills"
expect fail 'a link to ../other' "$root"

root="$(fixture absolute)"
rm "$root/.agents/skills"
ln -s "$root/.claude/skills" "$root/.agents/skills"
expect fail 'an absolute link to .claude/skills' "$root"

root="$(fixture name)"
skill_md "$root" --- 'name: other' 'description: A demo skill.' --- '' '# Demo'
expect fail 'name: other in folder demo' "$root"

root="$(fixture extra-key)"
skill_md "$root" --- 'name: demo' 'description: A demo skill.' 'allowed-tools: Bash' --- '' '# Demo'
expect fail 'an extra allowed-tools line' "$root"

root="$(fixture block)"
skill_md "$root" --- 'name: demo' 'description: >' '  A demo skill.' --- '' '# Demo'
expect fail 'a description: > block' "$root"

root="$(fixture block-empty)"
skill_md "$root" --- 'name: demo' 'description: |' --- '' '# Demo'
expect fail 'a description: | block with no line' "$root"

root="$(fixture colon)"
skill_md "$root" --- 'name: demo' 'description: Use when: the user asks.' --- '' '# Demo'
expect fail 'an unquoted ": " in the description' "$root"

# More values that YAML reads as a plain string, or once quoted the right way.
i=0
for value in \
    '"`server-prep.sh` checklist: use it for # steps."' \
    "'it''s a demo, use when: the user asks.'" \
    'A demo skill (Coolify, Dokploy...) for "analyse" requests, [x] and {y} inside.' \
    'A demo skill.   '; do
    i=$((i + 1))
    root="$(fixture "good-value-$i")"
    skill_md "$root" --- 'name: demo' "description: $value" --- '' '# Demo'
    expect pass "description: $value" "$root"
done

# More values that YAML can't read, or reads as something other than a non-empty string.
i=0
for value in \
    '`server-prep.sh` checklist.' \
    '  `server-prep.sh` checklist.' \
    'Use for:' \
    '"Use when: the user asks.' \
    "'Use when: the user asks.\"" \
    '"A "demo" skill."' \
    '"A demo\q skill."' \
    $'A demo\tskill.' \
    "'it's a demo.'" \
    "''" \
    '""' \
    ' ' \
    'A demo # skill.' \
    '[x] A demo skill.' \
    '{x} A demo skill.' \
    '@demo skill.' \
    '- A demo skill.' \
    '&demo skill.' \
    '*demo skill.' \
    '!demo skill.' \
    '%demo skill.' \
    '# A demo skill.' \
    ', A demo skill.'; do
    i=$((i + 1))
    root="$(fixture "bad-value-$i")"
    skill_md "$root" --- 'name: demo' "description: $value" --- '' '# Demo'
    expect fail "description: $value" "$root"
done

root="$(fixture blank)"
skill_md "$root" --- 'name: demo' '' 'description: A demo skill.' --- '' '# Demo'
expect fail 'a blank line in the frontmatter' "$root"

root="$(fixture two-names)"
skill_md "$root" --- 'name: demo' 'name: demo' 'description: A demo skill.' --- '' '# Demo'
expect fail 'two name lines' "$root"

root="$(fixture no-description)"
skill_md "$root" --- 'name: demo' --- '' '# Demo'
expect fail 'no description' "$root"

root="$(fixture no-closing)"
skill_md "$root" --- 'name: demo' 'description: A demo skill.' '' '# Demo'
expect fail 'no closing ---' "$root"

root="$(fixture no-frontmatter)"
skill_md "$root" '# Demo' '' 'A demo skill.'
expect fail 'no frontmatter' "$root"

root="$(fixture no-skill-md)"
mkdir "$root/.claude/skills/empty"
expect fail 'a skill folder without SKILL.md' "$root"

root="$(fixture no-skills)"
rm -r "$root/.claude/skills/demo"
expect fail 'no skill at all' "$root"
