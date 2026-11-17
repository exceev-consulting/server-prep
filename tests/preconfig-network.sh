#!/usr/bin/env bash
# Tests how server-preconfig.sh's network step comments out the old definition of the interface
# (issue #224): comment_out_iface must comment out every option of an "iface IFACE inet" block, also
# after a comment, a blank line or an unindented line, as ifupdown reads them, and nothing else.
# Fixture files under a temp folder: no root needed and nothing on the host changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRE="$SCRIPT_DIR/server-preconfig.sh"

# server-preconfig.sh runs main on load, so it cannot be sourced: load only the function under test.
eval "$(sed -n '/^comment_out_iface() {/,/^}/p' "$PRE")"
if ! declare -F comment_out_iface >/dev/null; then
    printf 'not ok: comment_out_iface not found in server-preconfig.sh\n'
    exit 1
fi

if ! tmp="$(mktemp -d)" || [[ -z $tmp || ! -d $tmp ]]; then
    printf 'not ok: mktemp -d failed, no temporary directory for the fixtures\n'
    exit 1
fi
trap 'rm -rf "$tmp"' EXIT

not_ok() {   # not_ok "message" [FILE]: stop, showing FILE when given
    printf 'not ok: %s\n' "$1"
    if [[ -n ${2:-} && -f $2 ]]; then sed 's/^/    | /' "$2"; fi
    exit 1
}

# What ifupdown makes of each active option line: "<iface> <family>: <option>", or "misplaced: <option>"
# outside any iface block. A stanza ends only at the next keyword (interfaces(5), ifupdown's config.c).
iface_options() {
    awk '{ sub(/^[ \t]+/, "") }
        /^#/ || NF == 0 { next }
        $1 == "iface" { cur = $2 " " $3; next }
        $1 == "mapping" || $1 == "rename" || $1 ~ /^source/ { cur = ""; next }
        $1 ~ /^(auto|allow-.+|no-auto-down|no-scripts)$/ { if (NF > 1) cur = ""; next }
        { print (cur == "" ? "misplaced" : cur) ": " $0 }'
}

# (a) The block the Debian installer writes for a fixed IP, with its indented comment (the issue).
printf '%s\n' \
    '# This file describes the network interfaces available on your system' \
    'source /etc/network/interfaces.d/*' \
    '' \
    '# The loopback network interface' \
    'auto lo' \
    'iface lo inet loopback' \
    '' \
    '# The primary network interface' \
    'allow-hotplug ens18' \
    'iface ens18 inet static' \
    $'\taddress 192.168.1.50/24' \
    $'\tgateway 192.168.1.1' \
    $'\t# dns-* options are implemented by the resolvconf package, if installed' \
    $'\tdns-nameservers 192.168.1.1' \
    $'\tdns-search example.com' > "$tmp/installer.in"
printf '%s\n' \
    '# This file describes the network interfaces available on your system' \
    'source /etc/network/interfaces.d/*' \
    '' \
    '# The loopback network interface' \
    'auto lo' \
    'iface lo inet loopback' \
    '' \
    '# The primary network interface' \
    '#preconfig# allow-hotplug ens18' \
    '#preconfig# iface ens18 inet static' \
    $'#preconfig# \taddress 192.168.1.50/24' \
    $'#preconfig# \tgateway 192.168.1.1' \
    $'\t# dns-* options are implemented by the resolvconf package, if installed' \
    $'#preconfig# \tdns-nameservers 192.168.1.1' \
    $'#preconfig# \tdns-search example.com' > "$tmp/installer.want"

# (b) Every way a block goes on in ifupdown: a blank line, an unindented option, a comment between
# options. Then the blocks that must stay: ens18's inet6 block, another interface, the "source" line
# step_network appends when the file has none, after a blank line, at the end.
printf '%s\n' \
    'auto lo' \
    'iface lo inet loopback' \
    '' \
    'auto ens18' \
    'iface ens18 inet static' \
    '    address 192.168.1.50/24' \
    '' \
    '    gateway 192.168.1.1' \
    'dns-nameservers 192.168.1.1' \
    '# a route to the office' \
    '    up ip route add 10.0.0.0/8 via 192.168.1.254' \
    '' \
    'iface ens18 inet6 static' \
    '    address 2001:db8::50/64' \
    '' \
    '# The second interface' \
    'allow-hotplug ens19' \
    'iface ens19 inet dhcp' \
    '    metric 200' \
    '' \
    'source /etc/network/interfaces.d/*' > "$tmp/blocks.in"
printf '%s\n' \
    'auto lo' \
    'iface lo inet loopback' \
    '' \
    '#preconfig# auto ens18' \
    '#preconfig# iface ens18 inet static' \
    '#preconfig#     address 192.168.1.50/24' \
    '' \
    '#preconfig#     gateway 192.168.1.1' \
    '#preconfig# dns-nameservers 192.168.1.1' \
    '# a route to the office' \
    '#preconfig#     up ip route add 10.0.0.0/8 via 192.168.1.254' \
    '' \
    'iface ens18 inet6 static' \
    '    address 2001:db8::50/64' \
    '' \
    '# The second interface' \
    'allow-hotplug ens19' \
    'iface ens19 inet dhcp' \
    '    metric 200' \
    '' \
    'source /etc/network/interfaces.d/*' > "$tmp/blocks.want"

# (c) A file with other keywords right after the block: each one ends it.
printf '%s\n' \
    'iface ens18 inet dhcp' \
    '    hostname web-01' \
    'mapping eth1' \
    '    script /usr/local/sbin/map-scheme' \
    'iface ens18 inet manual' \
    '    pre-up true' \
    'source-directory /etc/network/interfaces.d' \
    'iface ens18 inet dhcp' \
    'rename eth2=ens20' > "$tmp/keywords.in"
printf '%s\n' \
    '#preconfig# iface ens18 inet dhcp' \
    '#preconfig#     hostname web-01' \
    'mapping eth1' \
    '    script /usr/local/sbin/map-scheme' \
    '#preconfig# iface ens18 inet manual' \
    '#preconfig#     pre-up true' \
    'source-directory /etc/network/interfaces.d' \
    '#preconfig# iface ens18 inet dhcp' \
    'rename eth2=ens20' > "$tmp/keywords.want"

cases() {   # cases LABEL: every case, run once per awk
    local l=$1 name out
    for name in installer blocks keywords; do
        comment_out_iface ens18 < "$tmp/$name.in" > "$tmp/$name.got"
        diff "$tmp/$name.want" "$tmp/$name.got" > "$tmp/$name.diff" || not_ok "$l: $name" "$tmp/$name.diff"
        printf 'ok: %s: %s: the ens18 inet block is commented out, every other line byte for byte\n' "$l" "$name"
        comment_out_iface ens18 < "$tmp/$name.got" > "$tmp/$name.again"
        cmp -s "$tmp/$name.got" "$tmp/$name.again" || not_ok "$l: $name: a re-run changed the file"
        printf 'ok: %s: %s: a re-run changes nothing\n' "$l" "$name"
    done

    # What ifupdown reads now: no option of the old block is left, under lo or anywhere else.
    out=$(iface_options < "$tmp/installer.got")
    [[ -z $out ]] || not_ok "$l: installer: options left active: $out"
    printf 'ok: %s: installer: dns-nameservers and dns-search are no longer options of lo\n' "$l"
    out=$(iface_options < "$tmp/blocks.got")
    [[ $out == $'ens18 inet6: address 2001:db8::50/64\nens19 inet: metric 200' ]] \
        || not_ok "$l: blocks: ifupdown would read: $out"
    printf 'ok: %s: blocks: only the inet6 block and ens19 keep options\n' "$l"
    grep -qx 'source /etc/network/interfaces.d/\*' "$tmp/blocks.got" \
        || not_ok "$l: blocks: the source line after the block was commented out" "$tmp/blocks.got"
    printf 'ok: %s: blocks: the source line after the block stays active\n' "$l"

    # Another interface's name: nothing changes.
    comment_out_iface ens19 < "$tmp/installer.in" > "$tmp/other.got"
    cmp -s "$tmp/installer.in" "$tmp/other.got" || not_ok "$l: ens19: the installer file changed"
    printf 'ok: %s: an interface the file does not define: the file is left as is\n' "$l"
    comment_out_iface ens1 < "$tmp/installer.in" > "$tmp/prefix.got"
    cmp -s "$tmp/installer.in" "$tmp/prefix.got" || not_ok "$l: ens1 matched ens18"
    printf 'ok: %s: ens1 does not match ens18\n' "$l"
}

cases awk
if command -v mawk >/dev/null 2>&1; then
    # Debian and Ubuntu use mawk as awk: run the same cases through it.
    awk() { mawk "$@"; }
    cases mawk
    unset -f awk
else
    printf 'ok: skip the mawk run (mawk not installed)\n'
fi

printf 'ok: all server-preconfig.sh network cases\n'
