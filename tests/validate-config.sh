#!/usr/bin/env bash
# Tests server-prep.sh --validate on a good config and broken ones, built in a temp folder with a
# throwaway key. No root needed, nothing on the host changes and nothing is committed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/server-prep.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

out=""
status=0
fail() {   # fail MESSAGE: print it with the last output, then stop
    printf 'not ok: %s\n' "$1"
    [[ -n "$out" ]] && printf '%s\n' "$out" >&2
    exit 1
}
check() {   # check FILE [ARGS...]: run --validate on FILE with a clean environment, set out and status
    local file="$1"
    shift
    status=0
    out="$(env -i PATH="$PATH" HOME="${HOME:-/}" "$SCRIPT" --config "$file" --validate "$@" </dev/null 2>&1)" || status=$?
}
count() {   # count LEVEL: number of LEVEL lines in the last output
    grep -c "^$1 " <<< "$out"
}

command -v ssh-keygen >/dev/null || { printf 'not ok: ssh-keygen is needed to make a throwaway key\n'; exit 1; }
ssh-keygen -q -t ed25519 -N '' -C web-01 -f "$tmp/key" </dev/null || fail "ssh-keygen could not make a throwaway key"
pub="$(cat "$tmp/key.pub")"

# A complete and correct config, as KEY=value pairs
good=(
    "ADMIN_USER=admin"
    "ADMIN_PUBKEY=$pub"
    "PANEL=coolify"
    "PANEL_PUBKEY=$pub"
    "PANEL_ACCESS=tailscale,public"
    "PANEL_IP=203.0.113.10"
    "CLOUDFLARED_TOKEN="
    "SSH_PORT=822"
    "ADMIN_IPS=192.168.1.0/24 203.0.113.4 2001:db8::/32"
    "EXPOSE_WEB=yes"
    "EXTRA_PORTS=8000/tcp 6001"
    "CROWDSEC_LAPI_PORT=8091"
    "AUTO_REBOOT=no"
    "AUTO_REBOOT_TIME=04:00"
    "DISABLE_SERVICES=avahi-daemon cups apport"
    "LAPTOP_MODE=auto"
    "INSTALL_AIDE=yes"
    "TELEGRAM_IGNORE_USERS=root deploy"
    "AUDIT_URL=https://example.com/server-audit.sh?ref=main&x=\$1"
    "TIMEZONE=Europe/Paris"
    "SWAP_SIZE=2G"
    "PTRACE_SCOPE=2"
)

# Setup console style: double quotes with \" \\ \$ \` escapes and aligned # notes
{
    printf '# web-01.conf - made with the server-prep setup console\n'
    printf '# \303\251t\303\251 2026 : serveur web\n\n'   # UTF-8 text is not a control character
    printf '\tSSH_PORT="822"\t# indented with tabs\n'
    for kv in "${good[@]}"; do
        k="${kv%%=*}"; v="${kv#*=}"
        v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\$/\\\$}"; v="${v//\`/\\\`}"
        printf '%-40s # %s\n' "$k=\"$v\"" "note for $k"
    done
} > "$tmp/good.conf"
# Saved answers style (save_answers): printf %q, so '' for empty values and backslash escapes
{
    printf '# server-prep answers - reuse with: --config /etc/server-prep/server-prep.conf --yes\n'
    for kv in "${good[@]}"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done
    printf '%s=%q\n' DISABLE_SERVICES $'avahi-daemon\tcups'   # %q gives $'...'
} > "$tmp/saved.conf"

for f in good saved; do
    check "$tmp/$f.conf"
    [[ $status -eq 0 && "$out" == "config OK (0 warning(s), 0 note(s))" ]] ||
        fail "the $f config gives exit $status, want 0 and only \"config OK\""
    printf 'ok: a good config (%s style) gives exit 0 and config OK\n' "$f"
done

# --validate only validates, even with the options of a real run
check "$tmp/good.conf" --yes --dry-run --only ssh
[[ $status -eq 0 && "$out" == "config OK"* ]] || fail "--validate with --yes --dry-run --only ssh does more than validate"
printf 'ok: --validate with --yes --dry-run --only only validates\n'

# Old COOLIFY_* names are a note, not an error
sed -e 's/^PANEL_PUBKEY=/COOLIFY_PUBKEY=/' -e 's/^PANEL_ACCESS=/COOLIFY_ACCESS=/' "$tmp/good.conf" > "$tmp/old.conf"
check "$tmp/old.conf"
[[ $status -eq 0 && $(count NOTE) -eq 2 && $(count ERROR) -eq 0 && $(count WARN) -eq 0 ]] ||
    fail "a config with COOLIFY_PUBKEY and COOLIFY_ACCESS gives exit $status, want 0 with two notes"
printf 'ok: old COOLIFY_* names give exit 0 with a note each\n'

broken() {   # broken LABEL LINE WORDS: the good config + LINE gives exit 1 and one ERROR, on that line, with WORDS
    local label="$1" add="$2" want="$3" n err
    cp "$tmp/good.conf" "$tmp/broken.conf"
    printf '%s\n' "$add" >> "$tmp/broken.conf"
    n="$(wc -l < "$tmp/broken.conf")"
    check "$tmp/broken.conf"
    err="$(grep '^ERROR ' <<< "$out")"
    if [[ $status -ne 1 || $(count ERROR) -ne 1 || "$err" != "ERROR $tmp/broken.conf:$n "* || "$err" != *"$want"* ]]; then
        fail "$label gives exit $status, want 1 and one ERROR on line $n with \"$want\""
    fi
    printf 'ok: %s gives exit 1 and one error on its line\n' "$label"
}
broken "a typo in a key" 'PANEL_ACESS="public"' "did you mean PANEL_ACCESS?"
broken "a lowercase key" 'ssh_port="822"' "did you mean SSH_PORT?"
broken "true as a yes/no value" 'INSTALL_AIDE="true"' "write yes or no"
broken "LAPTOP_MODE=Yes" 'LAPTOP_MODE="Yes"' "write auto, yes or no"
broken "a bad PANEL_ACCESS item" 'PANEL_ACCESS="tailscale,publik"' '"publik"'
broken "public without PANEL_IP" 'PANEL_IP=""' "Set PANEL_IP to the public IP"
broken "a bad PANEL_IP" 'PANEL_IP="203.0.113.300"' "not an IP address"
broken "the placeholder key" 'ADMIN_PUBKEY="ssh-ed25519 AAAA... you@laptop"' "example placeholder"
broken "a key that is not a key" 'PANEL_PUBKEY="ssh-ed25519 not-a-key web-01"' "not a valid public key"
broken "SSH_PORT=70000" 'SSH_PORT="70000"' "from 1 to 65535"
broken "CROWDSEC_LAPI_PORT=0" 'CROWDSEC_LAPI_PORT="0"' "from 1 to 65535"
broken "a bad ADMIN_IPS item" 'ADMIN_IPS="192.168.1.300"' '"192.168.1.300"'
broken "an ADMIN_IPS item with leading zeros" 'ADMIN_IPS="192.168.001.050"' '"192.168.001.050"'   # ufw refuses it
broken "a PANEL_IP with a leading zero" 'PANEL_IP="010.0.0.1"' "not an IP address"
broken "a prefix length with a leading zero" 'ADMIN_IPS="192.168.1.0/024"' '"192.168.1.0/024"'
broken "a bad TELEGRAM_CHAT_ID" 'TELEGRAM_CHAT_ID="42 x"' "write the chat id"
broken "a TELEGRAM_IGNORE_USERS item that is no user" 'TELEGRAM_IGNORE_USERS="root \${PATH}"' "not a user name"
broken "an ADMIN_USER with a blank" 'ADMIN_USER="Admin User"' "not a user name"
broken "an ADMIN_USER with an @" 'ADMIN_USER="admin@web-01"' "not a user name"
broken "a bad EXTRA_PORTS item" 'EXTRA_PORTS="8000/sctp"' '"8000/sctp"'
broken "AUTO_REBOOT_TIME=25:00" 'AUTO_REBOOT_TIME="25:00"' "HH:MM"
broken "PTRACE_SCOPE=4" 'PTRACE_SCOPE="4"' "0, 1, 2 or 3"
broken "a SWAP_SIZE with a space" 'SWAP_SIZE="2 G"' "like 2G or 512M"
broken "an unknown step in ONLY" 'ONLY="ssh firewal"' '"firewal"'
if [[ -d /usr/share/zoneinfo ]]; then
    broken "an unknown TIMEZONE" 'TIMEZONE="Mars/Base"' "not a known timezone"
fi
# Lines that would run something if the file were sourced: refused, and never run
broken "a trailing command" "SSH_PORT=822 touch $tmp/pwned" "cannot be read safely"
broken "a redirect" "SSH_PORT=822>$tmp/pwned" "cannot be read safely"
broken "a command substitution" "SSH_PORT=\"\$(touch $tmp/pwned)\"" "cannot be read safely"
broken "a quoted command substitution" "SSH_PORT='\$(touch $tmp/pwned)'" "cannot hold"
broken "a ; in a value" 'TELEGRAM_CHAT_ID="42;x"' "cannot hold"
broken "a line that is not a setting" "touch $tmp/pwned" "not a setting"
broken "an arithmetic trap" "SSH_PORT=\$'a[\\x24(touch $tmp/pwned)]'" "once its escapes are read"
broken "PATH in a config" 'PATH="/nonexistent"' "PATH is not a known setting"
broken "BASH_ENV in a config" "BASH_ENV=\"$tmp/pwned\"" "not a known setting"
# Escapes that give back \$(, \` or ; once read: step_telegram writes these values into telegram.env,
# which root sources at every SSH login
broken "an escaped \$( in \$'...'" "TELEGRAM_IGNORE_USERS=\$'root \\x24(touch $tmp/pwned)'" "once its escapes are read"
broken "an escaped ; in \$'...'" "TELEGRAM_CHAT_ID=\$'1\\x3btouch $tmp/pwned'" "once its escapes are read"
broken "an escaped backtick in \$'...'" "TELEGRAM_CHAT_ID=\$'\\x60touch $tmp/pwned\\x60'" "once its escapes are read"
broken "a backslash-escaped \$(" "TELEGRAM_CHAT_ID=42\\\$\\(touch\\ $tmp/pwned\\)" "once its escapes are read"
broken "an escaped newline" "TELEGRAM_IGNORE_USERS=\$'root\\ntouch $tmp/pwned'" "once its escapes are read"
# Control characters: bash reads a form feed, a vertical tab or a carriage return inside a line as part
# of a word, so the # after it starts no comment and what follows runs
broken "a form feed before a #" "SSH_PORT=\"822\""$'\f'"#\$(touch $tmp/pwned)" "control character"
broken "a vertical tab before a #" "SSH_PORT=822"$'\v'"# ; touch $tmp/pwned" "control character"
broken "a carriage return inside a line" "TIMEZONE=UTC"$'\r'"#\$(touch $tmp/pwned)" "control character"
broken "a form feed then a comment" $'\f'"# \$(touch $tmp/pwned)" "control character"
# A NUL byte: bash drops it and runs the rest of the line, so it is refused
cp "$tmp/good.conf" "$tmp/broken.conf"
printf 'SSH_PORT=822\0$(touch %s/pwned)\n' "$tmp" >> "$tmp/broken.conf"
n="$(wc -l < "$tmp/broken.conf")"
check "$tmp/broken.conf"
[[ $status -eq 1 && $(count ERROR) -eq 1 && "$out" == *"ERROR $tmp/broken.conf:$n "*"NUL byte"* ]] ||
    fail "a NUL byte gives exit $status, want 1 and one NUL byte error on line $n"
printf 'ok: a NUL byte gives exit 1 and one error on its line\n'
[[ ! -e "$tmp/pwned" ]] || fail "a broken config ran a command"
printf 'ok: no broken config ran a command\n'

# Every unknown key is listed, not only the first one
cp "$tmp/good.conf" "$tmp/unknown.conf"
printf 'SSHPORT="822"\nADMIN_IP="192.168.1.50"\n' >> "$tmp/unknown.conf"
check "$tmp/unknown.conf"
[[ $status -eq 1 && $(count ERROR) -eq 2 && "$out" == *"did you mean SSH_PORT?"* && "$out" == *"did you mean ADMIN_IPS?"* ]] ||
    fail "two unknown keys give exit $status, want 1 and two errors with their suggestions"
printf 'ok: every unknown key is listed with a suggestion\n'

# A private key pasted into ADMIN_PUBKEY: one error, and no line of the key is printed
private_case() {   # private_case LABEL PREFIX WANT_LINE_OFFSET
    local label="$1" n l
    cp "$tmp/good.conf" "$tmp/private.conf"
    n=$(( $(wc -l < "$tmp/good.conf") + $3 ))
    { printf '%s' "$2"; cat "$tmp/key"; printf '"\n'; } >> "$tmp/private.conf"
    check "$tmp/private.conf"
    [[ $status -eq 1 && $(count ERROR) -eq 1 && "$out" == *"ERROR $tmp/private.conf:$n "*"private key"* ]] ||
        fail "$label gives exit $status, want 1 and one private key error on line $n"
    while IFS= read -r l; do
        [[ -n "$l" && "$out" == *"$l"* ]] && fail "$label prints a line of the private key"
    done < "$tmp/key"
    printf 'ok: %s gives one error and never prints the key\n' "$label"
}
private_case "a private key in ADMIN_PUBKEY" 'ADMIN_PUBKEY="' 1
private_case "a private key on the line after ADMIN_PUBKEY=\"" $'ADMIN_PUBKEY="\n' 2

# Windows line endings and a UTF-8 BOM: one error each, not one per line
sed 's/$/\r/' "$tmp/good.conf" > "$tmp/crlf.conf"
check "$tmp/crlf.conf"
[[ $status -eq 1 && $(count ERROR) -eq 1 && "$out" == *"CRLF"* ]] || fail "a CRLF file gives exit $status, want 1 and one error"
printf 'ok: Windows line endings give one error\n'
{ printf '\xef\xbb\xbf'; cat "$tmp/good.conf"; } > "$tmp/bom.conf"
check "$tmp/bom.conf"
[[ $status -eq 1 && $(count ERROR) -eq 1 && "$out" == *"BOM"* ]] || fail "a file with a BOM gives exit $status, want 1 and one error"
printf 'ok: a UTF-8 BOM gives one error\n'

# A secret in the file is a warning, plus one when other users can read the file; it is never printed
canary="canary-$RANDOM$RANDOM$RANDOM"
cp "$tmp/good.conf" "$tmp/secret.conf"
printf 'CLOUDFLARED_TOKEN="%s"\n' "$canary" >> "$tmp/secret.conf"
chmod 600 "$tmp/secret.conf"
check "$tmp/secret.conf"
[[ $status -eq 0 && $(count WARN) -eq 1 && "$out" == *"CLOUDFLARED_TOKEN holds a secret"* && "$out" != *"$canary"* ]] ||
    fail "a token in a 600 file gives exit $status, want 0 and one warning without the token"
chmod 644 "$tmp/secret.conf"
check "$tmp/secret.conf"
[[ $status -eq 0 && $(count WARN) -eq 2 && "$out" == *"chmod 600"* && "$out" != *"$canary"* ]] ||
    fail "a token in a 644 file gives exit $status, want 0 and two warnings without the token"
printf 'CLOUDFLARED_TOKEN="%s;x"\n' "$canary" >> "$tmp/secret.conf"
check "$tmp/secret.conf"
[[ $status -eq 1 && "$out" != *"$canary"* ]] || fail "a malformed token line gives exit $status or prints the token, want 1 without it"
printf 'ok: a secret gives a warning (two when others can read the file) and is never printed\n'

# A token pasted into a setting whose value errors print: never printed. The bot token in TELEGRAM_CHAT_ID (the two
# settings sit side by side) gets its own error, plus the chmod warning since the file now holds a secret.
# The fake tokens are built here so the file holds no token shape.
tg_canary="$((RANDOM + 100000)):AAEh${RANDOM}Canary${RANDOM}Token${RANDOM}_xYz"
broken "a bot token in TELEGRAM_CHAT_ID" "TELEGRAM_CHAT_ID=\"$tg_canary\"" "looks like the bot token"
[[ "$out" != *"${tg_canary#*:}"* ]] || fail "a bot token in TELEGRAM_CHAT_ID is printed"
chmod 644 "$tmp/broken.conf"
check "$tmp/broken.conf"
[[ $status -eq 1 && "$out" == *"chmod 600"* && "$out" != *"${tg_canary#*:}"* ]] ||
    fail "a bot token in TELEGRAM_CHAT_ID of a 644 file gives exit $status, want 1 and a chmod warning without the token"
printf 'ok: a bot token in TELEGRAM_CHAT_ID is never printed, and the file mode is checked\n'
key_canary="cl${RANDOM}canary${RANDOM}enroll${RANDOM}key"   # lowercase and digits, like a CrowdSec enroll key
for kv in "ADMIN_IPS=192.168.1.50 $key_canary" "PANEL_ACCESS=tailscale,$key_canary" "TELEGRAM_CHAT_ID=$key_canary" \
          "ONLY=ssh $key_canary"; do
    broken "a token in ${kv%%=*}" "${kv%%=*}=\"${kv#*=}\"" "looks like a token (not shown)"
    [[ "$out" != *"$key_canary"* ]] || fail "a token in ${kv%%=*} is printed"
done
printf 'ok: a token in a checked setting is never printed\n'
# Plain values are still shown: a long service name, an IPv6 address
broken "a bad IPv6 address after a long service name" \
    $'DISABLE_SERVICES="systemd-networkd-wait-online"\nADMIN_IPS="2001:db8:85a3::8a2e:370:73345"' '"2001:db8:85a3::8a2e:370:73345"'
[[ "$out" == *'WARN '*'"systemd-networkd-wait-online"'* ]] || fail "a long service name is not shown"
printf 'ok: long plain values are still shown\n'

# Lockout: public access and no ADMIN_IPS
cp "$tmp/good.conf" "$tmp/lockout.conf"
printf 'PANEL_ACCESS="public"\nADMIN_IPS=""\n' >> "$tmp/lockout.conf"
check "$tmp/lockout.conf"
[[ $status -eq 0 && $(count WARN) -eq 1 && "$out" == *"WARN "*"locked out"*"ADMIN_IPS"* ]] ||
    fail "public access without ADMIN_IPS gives exit $status, want 0 and a lockout warning"
printf 'ok: public access without ADMIN_IPS gives a lockout warning\n'
cp "$tmp/good.conf" "$tmp/noaccess.conf"
printf 'PANEL_ACCESS=""\n' >> "$tmp/noaccess.conf"
check "$tmp/noaccess.conf"
[[ $status -eq 0 && $(count WARN) -eq 1 && "$out" == *"root login will be refused everywhere"* ]] ||
    fail "a panel key without PANEL_ACCESS gives exit $status, want 0 and one warning"
printf 'ok: a panel key without PANEL_ACCESS gives a warning\n'
cp "$tmp/good.conf" "$tmp/rootadmin.conf"
printf 'ADMIN_USER="root"\n' >> "$tmp/rootadmin.conf"
check "$tmp/rootadmin.conf"
[[ $status -eq 0 && $(count WARN) -eq 1 && "$out" == *"ADMIN_USER is root"* ]] ||
    fail "ADMIN_USER=root gives exit $status, want 0 and one warning"
printf 'ok: ADMIN_USER=root gives a warning\n'

# A value the file does not set has - for its line, and one line explains the -
grep -v '^ADMIN_PUBKEY=' "$tmp/good.conf" > "$tmp/nokey.conf"
check "$tmp/nokey.conf"
[[ $status -eq 0 && $(count WARN) -eq 1 && "$out" == *"WARN $tmp/nokey.conf:- ADMIN_PUBKEY is empty"* &&
   $(grep -c '^(- instead of a line number' <<< "$out") -eq 1 ]] ||
    fail "a config without ADMIN_PUBKEY gives exit $status, want 0, one warning on line - and one line that explains it"
printf 'ok: a value the file does not set has - for its line, explained once\n'

# The example as it is: only its two placeholder keys are errors
check "$SCRIPT_DIR/server-prep.conf.example"
admin_line="$(grep -n '^ADMIN_PUBKEY=' "$SCRIPT_DIR/server-prep.conf.example" | cut -d: -f1)"
panel_line="$(grep -n '^PANEL_PUBKEY=' "$SCRIPT_DIR/server-prep.conf.example" | cut -d: -f1)"
[[ $status -eq 1 && $(count ERROR) -eq 2 && "$out" == *".example:$admin_line ADMIN_PUBKEY"* &&
   "$out" == *".example:$panel_line PANEL_PUBKEY"* ]] ||
    fail "server-prep.conf.example gives exit $status, want 1 and errors on lines $admin_line and $panel_line only"
printf 'ok: server-prep.conf.example gives exactly its two placeholder errors\n'

# --validate writes nothing: no file in the current folder or in TMPDIR
mkdir "$tmp/cwd" "$tmp/tmpdir"
(cd "$tmp/cwd" && env -i PATH="$PATH" TMPDIR="$tmp/tmpdir" "$SCRIPT" --config "$tmp/good.conf" --validate >/dev/null 2>&1 </dev/null) ||
    fail "the good config from an empty folder does not give exit 0"
[[ -z "$(ls -A "$tmp/cwd")" && -z "$(ls -A "$tmp/tmpdir")" ]] || fail "--validate wrote a file"
printf 'ok: --validate writes no file\n'

# KNOWN_SETTINGS lists every setting of the settings block, plus ONLY, SKIP and the old names
settings="$(sed -nE 's/^([A-Z][A-Z0-9_]*)="\$\{\1:-.*/\1/p' "$SCRIPT" | sort -u)"
known="$(eval "$(awk '/^KNOWN_SETTINGS="/ { f = 1 } f { print } f && /"$/ { exit }' "$SCRIPT")"
         # shellcheck disable=SC2086   # split the list into one name per line
         printf '%s\n' ${KNOWN_SETTINGS:-} | grep -vxE 'ONLY|SKIP|COOLIFY_(PUBKEY|ACCESS|IP)' | sort -u)"
if [[ -z "$settings" || "$settings" != "$known" ]]; then
    out="$(diff <(printf '%s\n' "$settings") <(printf '%s\n' "$known"))"
    fail "KNOWN_SETTINGS in server-prep.sh does not match the settings block (< settings, > KNOWN_SETTINGS)"
fi
printf 'ok: KNOWN_SETTINGS matches the settings block\n'

# Every yes/no setting (default yes or no in the settings block, and EXPOSE_WEB) refuses a value that is neither
yesno="$(sed -nE 's/^([A-Z][A-Z0-9_]*)="\$\{\1:-(yes|no)\}".*/\1/p' "$SCRIPT")"
[[ -n "$yesno" ]] || fail "no yes/no setting found in the settings block of server-prep.sh"
for k in $yesno EXPOSE_WEB; do
    cp "$tmp/good.conf" "$tmp/yesno.conf"
    printf '%s="ye"\n' "$k" >> "$tmp/yesno.conf"
    check "$tmp/yesno.conf"
    [[ $status -eq 1 && $(count ERROR) -eq 1 && "$out" == *"$k is \"ye\": write yes or no"* ]] ||
        fail "$k=\"ye\" gives exit $status, want 1 and one \"write yes or no\" error (add $k to the yes/no list of validate_values)"
done
printf 'ok: every yes/no setting refuses a value that is neither yes nor no\n'

printf 'ok: all --validate cases\n'
