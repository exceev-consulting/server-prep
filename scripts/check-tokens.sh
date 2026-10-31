#!/usr/bin/env bash
# Fails when a copy of the design tokens differs from site/tokens.css.
#
# site/tokens.css holds the colour, type and spacing tokens of the setup console and the brand
# page. A page that must also work on its own, like the e2e report, keeps a copy of the token
# blocks in its own CSS. This check keeps every copy equal to the source.
#
# It compares the custom properties (--name: value) of three blocks: light (:root), dark by the
# system (:root:not([data-theme="light"]) inside @media (prefers-color-scheme: dark)) and dark
# by choice (:root[data-theme="dark"]). Comments, spacing and every other rule are ignored. In
# the source, the two dark blocks must also be equal. It also checks the colour ramps of the brand
# page (sections 2.2 and 2.4 of site/brand/index.html), which print the token values as text.
#
# Usage: scripts/check-tokens.sh [copy.css ...]
#   Each copy is a CSS file. With no argument it checks the known copies and skips one that is
#   not in this tree (the e2e report arrives with its own pull request).
#   Exit status: 0 all equal, 1 a difference, 2 the source is missing or unreadable.
set -euo pipefail

# copies given on the command line are relative to where the check was started
args=()
for a in "$@"; do
    if [[ $a == /* ]]; then args+=("$a"); else args+=("$PWD/$a"); fi
done
cd "$(dirname "$0")/.."

SOURCE=site/tokens.css
KNOWN_COPIES=(tests/e2e/report/report.css)
BRAND_PAGE=site/brand/index.html

# Prints one line per token, "<block> --name: value", sorted. Blocks: light, dark-system, dark-choice.
tokens() {
    awk '
        function trim(s) { gsub(/[ \t\r\n]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
        function has(list, item,   parts, n, i) {
            n = split(list, parts, ",")
            for (i = 1; i <= n; i++) if (trim(parts[i]) == item) return 1
            return 0
        }
        function block() {
            if (depth == 1 && has(sel[1], ":root")) return "light"
            if (depth == 1 && has(sel[1], ":root[data-theme=\"dark\"]")) return "dark-choice"
            if (depth == 2 && sel[1] ~ /^@media/ && sel[1] ~ /prefers-color-scheme: *dark/ \
                && has(sel[2], ":root:not([data-theme=\"light\"])")) return "dark-system"
            return ""
        }
        function decl(s,   b, p, name) {
            b = block()
            p = index(s, ":")
            if (b == "" || p == 0) return
            name = trim(substr(s, 1, p - 1))
            if (name ~ /^--/) print b, name ": " trim(substr(s, p + 1))
        }
        { text = text $0 "\n" }
        END {
            # drop comments, then walk the rules one character at a time
            while ((i = index(text, "/*")) > 0) {
                j = index(substr(text, i + 2), "*/")
                text = (j == 0) ? substr(text, 1, i - 1) : substr(text, 1, i - 1) substr(text, i + j + 3)
            }
            depth = 0; buf = ""; q = ""; par = 0
            n = length(text)
            for (k = 1; k <= n; k++) {
                c = substr(text, k, 1)
                if (q != "") {                          # in a string: only its own quote ends it
                    buf = buf c
                    if (c == "\\") buf = buf substr(text, ++k, 1)
                    else if (c == q) q = ""
                    continue
                }
                if (c == "\"" || c == "\047") { q = c; buf = buf c; continue }
                if (c == "(") par++
                else if (c == ")" && par > 0) par--
                if (par > 0) { buf = buf c; continue }  # a ; { or } in url(...) belongs to the value
                if (c == "{") { sel[++depth] = trim(buf); buf = "" }
                else if (c == "}") { decl(buf); buf = ""; if (depth > 0) depth-- }
                else if (c == ";") { decl(buf); buf = "" }
                else buf = buf c
            }
        }
    ' "$1" | LC_ALL=C sort
}

# Prints "ok <line> <block> --name: #HEX" for each swatch of the brand page, or "bad <line>: ..."
# when the swatch's colour, copied value and label disagree. The light and rack ramps show light
# values, the dark ramp dark ones.
swatches() {
    awk -v re='<i style="background:#[0-9A-Fa-f]+"></i><span>--[a-z0-9-]+<br><button class="hex" type="button" data-copy="#[0-9A-Fa-f]+">#[0-9A-Fa-f]+</button>' '
        /class="rl">Light theme</ { b = "light" }
        /class="rl">Dark theme</ { b = "dark-choice" }
        /class="rk-sw"/ { b = "light" }
        b != "" {
            rest = $0
            while (match(rest, re)) {
                s = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
                bg = s; sub(/^<i style="background:/, "", bg); sub(/".*/, "", bg)
                name = s; sub(/.*<span>/, "", name); sub(/<br>.*/, "", name)
                cp = s; sub(/.*data-copy="/, "", cp); sub(/".*/, "", cp)
                shown = s; sub(/.*">/, "", shown); sub(/<\/button>$/, "", shown)
                if (bg != cp || cp != shown) print "bad", FNR ": " name " paints " bg ", copies " cp " and reads " shown
                else print "ok", FNR, b, name ":", cp
            }
        }
    ' "$1"
}

[[ -r $SOURCE ]] || { echo "check-tokens: $SOURCE not found" >&2; exit 2; }
src=$(tokens "$SOURCE")
for b in light dark-system dark-choice; do
    grep -q "^$b " <<<"$src" || { echo "check-tokens: $SOURCE has no $b block" >&2; exit 2; }
done

rc=0
# The source's two dark blocks: the system and the toggle must give the same dark theme.
if ! diff <(sed -n 's/^dark-system //p' <<<"$src") <(sed -n 's/^dark-choice //p' <<<"$src") >/dev/null; then
    echo "check-tokens: $SOURCE: the two dark blocks differ (< system, > choice):"
    diff <(sed -n 's/^dark-system //p' <<<"$src") <(sed -n 's/^dark-choice //p' <<<"$src") | grep '^[<>]' || true
    rc=1
fi

if (($#)); then copies=("${args[@]}"); else copies=("${KNOWN_COPIES[@]}"); fi
for copy in "${copies[@]}"; do
    if [[ ! -e $copy ]]; then
        if (($#)); then echo "check-tokens: $copy not found" >&2; rc=1; else echo "check-tokens: $copy not in this tree, skipped"; fi
        continue
    fi
    if out=$(diff <(echo "$src") <(tokens "$copy")); then
        echo "check-tokens: $copy matches $SOURCE ($(grep -c . <<<"$src") values)"
    else
        echo "check-tokens: $copy differs from $SOURCE (< source, > copy):"
        grep '^[<>]' <<<"$out" || true
        rc=1
    fi
done

if [[ -r $BRAND_PAGE ]]; then
    n=0 bad=0
    while read -r kind rest; do
        if [[ $kind == bad ]]; then echo "check-tokens: $BRAND_PAGE:$rest"; bad=1; continue; fi
        read -r line want <<<"$rest"
        n=$((n + 1))
        if ! grep -qxF "$want" <<<"$src"; then
            echo "check-tokens: $BRAND_PAGE:$line: the swatch says ${want#* }, $SOURCE has: $(grep -F "${want% *} " <<<"$src" || echo "no such token")"
            bad=1
        fi
    done < <(swatches "$BRAND_PAGE")
    # a swatch whose markup changed would drop out of the check: count them another way
    total=$(grep -o 'class="sw"' "$BRAND_PAGE" | wc -l || true)
    if ((n == 0 || n != total)); then
        echo "check-tokens: $BRAND_PAGE: $n of $total colour swatches are in the expected format, update the page or the check"
        bad=1
    fi
    if ((bad)); then rc=1; else echo "check-tokens: $BRAND_PAGE swatches match $SOURCE ($n swatches)"; fi
else
    echo "check-tokens: $BRAND_PAGE not found" >&2
    rc=1
fi
exit "$rc"
