# shellcheck shell=bash
# Answers server-prep.sh's questions the way a person at a terminal would.
# Sourced, not run. The remote side gets a real terminal (ssh -tt), so the script's
# "read ... < /dev/tty" prompts work; this side reads the screen and types the answers.

ansi_strip() { sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g; s/\r//g'; }

answer_for() {   # answer_for "question": the answer from $ANSWERS (first matching regex), else Enter
    local q="$1" re ans
    while IFS=$'\t' read -r re ans; do
        [[ -z "$re" || "$re" == \#* ]] && continue
        if [[ "$q" =~ $re ]]; then
            ans="${ans//\{ADMIN_PUBKEY\}/$(cat "$WORK/keys/admin.pub")}"
            ans="${ans//\{PANEL_PUBKEY\}/$(cat "$WORK/keys/panel.pub")}"
            printf '%s' "$ans"
            return 0
        fi
    done < "$ANSWERS"
    return 1
}

# interact LOG USER KEY PORT COMMAND: run COMMAND in the VM on a terminal and answer it.
# Every question and answer is written to LOG. Returns the command's exit status
# (255 when the connection broke, 124 when the screen stayed still for IDLE_S seconds).
interact() {
    local log="$1" user="$2" key="$3" port="$4" cmd="$5"
    local buf="" chunk tail q ans rc last=$SECONDS idle="${IDLE_S:-900}"
    coproc IA { ssh -tt "${SSH_OPTS[@]}" -i "$WORK/keys/$key" -p "$port" "$user@127.0.0.1" "$cmd" 2>&1; }
    local in="${IA[1]}" out="${IA[0]}" pid=$IA_PID
    while true; do
        chunk=""
        IFS= read -r -t 0.5 -N 4096 -u "$out" chunk
        rc=$?
        if [[ -n "$chunk" ]]; then
            printf '%s' "$chunk" >> "$log"
            buf+="$chunk"
            last=$SECONDS
        fi
        ((rc == 1)) && break                 # end of output
        if ((SECONDS - last > idle)); then
            printf '\n[e2e] nothing on screen for %ss, giving up\n' "$idle" >> "$log"
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        [[ -z "$chunk" ]] || continue        # wait until the screen is still before answering
        tail="$(printf '%s' "${buf##*$'\n'}" | ansi_strip)"
        q=""
        if [[ "$tail" =~ ^\?\ (.+):\ $ ]]; then
            q="${BASH_REMATCH[1]}"
            q="${q% \[*\]}"                  # drop the [default] part
            if ans="$(answer_for "$q")"; then
                printf '\n[e2e] answered "%s" to: %s\n' "$ans" "$q" >> "$log"
            else
                ans=""
                printf '\n[e2e] kept the default for: %s\n' "$q" >> "$log"
            fi
        elif [[ "$tail" =~ (New|Retype new)\ password:\ ?$ ]]; then
            q=password ans="$E2E_ADMIN_PASSWORD"
            printf '\n[e2e] typed the admin password\n' >> "$log"
        elif [[ "$tail" =~ Result\ \[y/n/s\]:\ $ ]]; then
            # The SSH safety check: test a NEW login on the new port, as the script asks.
            q=ssh-check
            if ssh_as "$ANSWER_ADMIN_USER" admin "$P822" true 2>/dev/null; then ans=y; else ans=n; fi
            printf '\n[e2e] new login on port 822: %s\n' "$ans" >> "$log"
        fi
        if [[ -n "$q" ]]; then
            printf '%s\r' "$ans" >&"$in"
            buf=""
        fi
    done
    { exec {in}>&-; } 2>/dev/null
    wait "$pid"
}
