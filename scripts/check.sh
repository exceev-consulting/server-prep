#!/usr/bin/env bash
# check.sh - run the lint checks of CI on your machine: syntax, ShellCheck, --help, site data,
# design tokens and the quick tests. It runs the checks of .github/workflows/lint.yml, with
# ShellCheck pinned to 0.11.0 (CI may use another ShellCheck version until lint.yml runs this
# script). It never calls sudo, needs no root and changes nothing on the system.
#
# Usage:
#   scripts/check.sh                    run every section
#   scripts/check.sh --only <section>   run one section
#   scripts/check.sh --list             list the sections
#   scripts/check.sh -h|--help          show this help
#
# It prints one line per section (OK, FAIL or SKIP), then a summary. The output of a failed
# section (ShellCheck findings, test output) is printed under its FAIL line.
#
# Sections, in run order:
#   syntax        bash -n on every script, one file per call
#   lint          ShellCheck -S warning on the same files, with the pinned ShellCheck
#   help          --help of server-prep.sh, server-preconfig.sh and server-audit.sh
#   data          scripts/gen-data.sh --check: the site data matches the scripts (needs jq)
#   tokens        scripts/check-tokens.sh: the design token copies match site/tokens.css
#   exit-status   tests/exit-status.sh: argument and exit-code checks, and the tests it runs (needs jq, ssh-keygen)
#   swap          tests/swap.sh: swap file creation with fake commands
#   e2e-report    tests/e2e-report.sh: the e2e report builder on fake results (needs jq)
#   e2e-pages     tests/e2e-pages.sh: the e2e pages builder with a stub gh (needs jq, unzip, python3)
#   consistency   scripts/check-consistency.sh: steps, README step table, config example, saved answers, questions and audit checks agree
#
# ShellCheck: the lint section uses ShellCheck 0.11.0. A shellcheck on PATH is used only when it
# is that version. Otherwise the release archive for your system is downloaded once to
# ${XDG_CACHE_HOME:-~/.cache}/server-prep/. Its SHA-256 is checked on every run, then ShellCheck is
# unpacked into a temporary folder and run from there. A checksum mismatch stops the script.
#
# Needs bash 5, curl, tar and sha256sum (or shasum on macOS). Some sections also need jq, ssh-keygen,
# unzip and python3 (see the list above). When one is missing, the sections that need it show SKIP on
# your machine; CI has them all, and there a missing one is a FAIL.
# Linux is the reference platform (CI runs ubuntu-latest). On macOS, syntax, lint and help match
# CI; the other sections may need the GNU tools.
#
# Exit status: 0 every section passed or was skipped, 1 a section failed, 2 a usage error, bash
# older than 5, or no verified ShellCheck.
#
# Add a section (tests #37, docs #39, security #40): one line in SECTIONS and one
# section_<name> function (a dash in the name becomes an underscore).
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then echo "bash 5 needed (macOS: brew install bash)" >&2; exit 2; fi
set -euo pipefail
export LC_ALL=C
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ShellCheck (https://github.com/koalaman/shellcheck, GPL-3.0) is downloaded on first use, never bundled.
# Update the version and the four hashes together; hashes are the SHA-256 of the release .tar.gz
# assets, shown on the GitHub release page.
SHELLCHECK_VERSION="0.11.0"
declare -A SHELLCHECK_SHA256=(
    [linux.x86_64]="b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6"
    [linux.aarch64]="68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc"
    [darwin.x86_64]="c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51"
    [darwin.aarch64]="339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f"
)
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/server-prep"

# The files of the Syntax and ShellCheck steps of .github/workflows/lint.yml, in the same order.
# The Lint step of .github/workflows/release.yml checks a part of them. Keep the three lists in
# sync until both workflows run this script. No nullglob, as in lint.yml: when a folder is gone,
# its pattern stays as written and the syntax and lint sections fail on it, instead of checking
# fewer files without a word.
FILES=(server-prep.sh server-audit.sh server-preconfig.sh extras/github-runners/*.sh scripts/*.sh tests/*.sh tests/e2e/*.sh tests/e2e/lib/*.sh)
HELP_SCRIPTS=(server-prep.sh server-preconfig.sh server-audit.sh)

# One line per section, in run order: name|gate|tools|description
#   gate: a file the section needs; when it is missing, the section is skipped. "-": always runs
#         (a missing file is then a FAIL, as in CI).
#   tools: commands the section needs, space-separated. "-": none.
SECTIONS=(
    "syntax|-|-|bash -n on every script, one file per call"
    "lint|-|-|ShellCheck -S warning on every script, with the pinned ShellCheck $SHELLCHECK_VERSION"
    "help|-|-|--help of server-prep.sh, server-preconfig.sh and server-audit.sh"
    "data|-|jq|the site data matches the scripts (scripts/gen-data.sh --check)"
    "tokens|-|-|the design token copies match site/tokens.css (scripts/check-tokens.sh)"
    "exit-status|-|jq ssh-keygen|argument and exit-code checks, and the tests they run (tests/exit-status.sh)"
    "swap|-|-|swap file creation with fake commands (tests/swap.sh)"
    "e2e-report|-|jq|the e2e report builder on fake results (tests/e2e-report.sh)"
    "e2e-pages|-|jq unzip python3|the e2e pages builder with a stub gh (tests/e2e-pages.sh)"
    "consistency|-|-|steps, README, config example, saved answers, questions and audit agree (scripts/check-consistency.sh)"
)
NAMES=()
NAME_WIDTH=0
for entry in "${SECTIONS[@]}"; do
    NAMES+=("${entry%%|*}")
    if [[ ${#NAMES[-1]} -gt $NAME_WIDTH ]]; then NAME_WIDTH=${#NAMES[-1]}; fi
done

die() { echo "check.sh: $*" >&2; exit 2; }

usage() {   # the header comment, without the "# " (the working directory is the repo root)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' scripts/check.sh
}

list_sections() {
    local entry name gate _ desc state
    for entry in "${SECTIONS[@]}"; do
        IFS='|' read -r name gate _ desc <<<"$entry"
        if [[ $gate != - ]]; then
            if [[ -e $gate ]]; then state=present; else state=missing; fi
            desc="$desc; runs when $gate exists ($state)"
        fi
        printf '%-*s  %s\n' "$NAME_WIDTH" "$name" "$desc"
    done
}

is_section() {
    local name
    for name in "${NAMES[@]}"; do
        [[ $name == "$1" ]] && return 0
    done
    return 1
}

# --- ShellCheck --------------------------------------------------------------

sha256_of() {   # prints the SHA-256 of a file
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}

# Sets SHELLCHECK to ShellCheck $SHELLCHECK_VERSION: the copy on PATH when it is that version,
# otherwise the pinned release from the cache (downloaded first when missing), whose SHA-256 is
# checked in this run before it is unpacked into $WORK. Stops with exit 2 when there is none.
find_shellcheck() {
    local v="$SHELLCHECK_VERSION" path_version os arch key want archive url tmp got
    if command -v shellcheck >/dev/null 2>&1; then
        path_version="$(shellcheck --version 2>/dev/null | sed -n 2p)" || path_version=""
        if [[ $path_version == "version: $v" ]]; then
            SHELLCHECK="$(command -v shellcheck)"
            return 0
        fi
        path_version="${path_version#version: }"
        echo "shellcheck on PATH is version ${path_version:-unknown}, not $v: using the pinned ShellCheck $v"
    fi

    case "$(uname -s)" in
        Linux) os=linux ;;
        Darwin) os=darwin ;;
        *) os="$(uname -s)" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) arch="$(uname -m)" ;;
    esac
    key="$os.$arch"
    want="${SHELLCHECK_SHA256[$key]:-}"
    [[ -n $want ]] || die "no pinned ShellCheck for $os $arch: install ShellCheck $v on PATH"
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
        || die "sha256sum or shasum needed to check ShellCheck: install coreutils, or install ShellCheck $v on PATH"
    command -v tar >/dev/null 2>&1 || die "tar needed to unpack ShellCheck: install tar, or install ShellCheck $v on PATH"

    archive="$CACHE_DIR/shellcheck-v$v.$key.tar.gz"
    url="https://github.com/koalaman/shellcheck/releases/download/v$v/shellcheck-v$v.$key.tar.gz"
    if [[ ! -f $archive ]]; then
        command -v curl >/dev/null 2>&1 || die "curl needed to download ShellCheck $v: install curl, or install ShellCheck $v on PATH"
        mkdir -p "$CACHE_DIR"
        echo "Downloading ShellCheck $v ($os $arch) to $CACHE_DIR"
        # a temporary file in the same folder, renamed once checked: an interrupted or concurrent
        # run never leaves a partial archive under the trusted name
        tmp="$(mktemp "$CACHE_DIR/.shellcheck-download.XXXXXX")"
        DOWNLOAD_TMP="$tmp"
        if ! curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize 33554432 --retry 3 \
                --connect-timeout 20 -o "$tmp" "$url"; then
            rm -f "$tmp"
            die "could not download ShellCheck $v ($url): check the network, or install ShellCheck $v on PATH; other sections still run with --only <section>"
        fi
        got="$(sha256_of "$tmp")"
        if [[ $got != "$want" ]]; then
            rm -f "$tmp"
            die "checksum mismatch for $url: expected $want, got $got"
        fi
        mv -f "$tmp" "$archive"
        DOWNLOAD_TMP=""
    fi

    # Check the bytes that will run, on every run: a copy of the cached archive, unpacked here.
    cp "$archive" "$WORK/shellcheck.tar.gz"
    got="$(sha256_of "$WORK/shellcheck.tar.gz")"
    [[ $got == "$want" ]] \
        || die "cached $archive fails its SHA-256 check (expected $want, got $got): delete it and run again to download it again"
    tar -xzf "$WORK/shellcheck.tar.gz" -C "$WORK" "shellcheck-v$v/shellcheck" \
        || die "could not unpack shellcheck-v$v/shellcheck from $archive"
    SHELLCHECK="$WORK/shellcheck-v$v/shellcheck"
}

# --- Sections ----------------------------------------------------------------
# Each section runs from the repo root with its output in a log, and sets DETAIL for its OK/FAIL line.
# They run in an `if`, where set -e is off, so each one returns its failure itself.

section_syntax() {
    local f rc=0 failed=()
    DETAIL="${#FILES[@]} files"
    for f in "${FILES[@]}"; do
        bash -n "$f" || { failed+=("$f"); rc=1; }
    done
    [[ $rc -eq 0 ]] || echo "bash -n failed: ${failed[*]}"
    return "$rc"
}

section_lint() {
    DETAIL="$("$SHELLCHECK" --version | sed -n 2p), ${#FILES[@]} files"
    "$SHELLCHECK" -S warning "${FILES[@]}"
}

section_help() {
    local s rc=0
    DETAIL="${HELP_SCRIPTS[*]}"
    for s in "${HELP_SCRIPTS[@]}"; do
        ./"$s" --help >/dev/null || { echo "$s --help failed"; rc=1; }
    done
    return "$rc"
}

section_data() {
    DETAIL="scripts/gen-data.sh --check"
    scripts/gen-data.sh --check
}

section_tokens() {
    DETAIL="scripts/check-tokens.sh"
    scripts/check-tokens.sh
}

section_exit_status() {
    DETAIL="tests/exit-status.sh"
    bash tests/exit-status.sh
}

section_swap() {
    DETAIL="tests/swap.sh"
    bash tests/swap.sh
}

section_e2e_report() {
    DETAIL="tests/e2e-report.sh"
    bash tests/e2e-report.sh
}

section_e2e_pages() {
    DETAIL="tests/e2e-pages.sh"
    bash tests/e2e-pages.sh
}

section_consistency() {
    DETAIL="scripts/check-consistency.sh"
    bash scripts/check-consistency.sh
}

# --- Options -----------------------------------------------------------------

ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)
            if [[ $# -lt 2 || -z $2 ]]; then
                { echo "--only needs a section name. Sections:"; list_sections; } >&2
                exit 2
            fi
            if ! is_section "$2"; then
                { echo "Unknown section: $2. Sections:"; list_sections; } >&2
                exit 2
            fi
            ONLY="$2"
            shift 2
            ;;
        --list) list_sections; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

# --- Run ---------------------------------------------------------------------

DOWNLOAD_TMP=""
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check.XXXXXX")"
trap 'rm -rf "$WORK"; [[ -z $DOWNLOAD_TMP ]] || rm -f "$DOWNLOAD_TMP"' EXIT

SHELLCHECK=""
if [[ -z $ONLY || $ONLY == lint ]]; then
    find_shellcheck
fi

line() {   # line STATUS NAME [DETAIL]
    if [[ -n ${3:-} ]]; then
        printf '%-6s%-*s  %s\n' "$1" "$NAME_WIDTH" "$2" "$3"
    else
        printf '%-6s%s\n' "$1" "$2"
    fi
}

n_ok=0
n_fail=0
n_skip=0
failed=()
for entry in "${SECTIONS[@]}"; do
    IFS='|' read -r name gate tools _ <<<"$entry"
    [[ -z $ONLY || $ONLY == "$name" ]] || continue

    if [[ $gate != - && ! -e $gate ]]; then
        line SKIP "$name" "$gate not found"
        n_skip=$((n_skip + 1))
        continue
    fi

    missing=()
    if [[ $tools != - ]]; then
        for tool in $tools; do
            command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
        done
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ ${CI:-} == true ]]; then
            line FAIL "$name" "needs ${missing[*]}"
            n_fail=$((n_fail + 1))
            failed+=("$name")
        else
            line SKIP "$name" "needs ${missing[*]} (install it; CI runs this check)"
            n_skip=$((n_skip + 1))
        fi
        continue
    fi

    DETAIL=""
    log="$WORK/$name.log"
    if "section_${name//-/_}" </dev/null >"$log" 2>&1; then
        line OK "$name" "$DETAIL"
        n_ok=$((n_ok + 1))
    else
        line FAIL "$name" "$DETAIL"
        sed 's/^/    /' "$log"
        n_fail=$((n_fail + 1))
        failed+=("$name")
    fi
done

summary="Summary: $n_ok OK, $n_fail FAIL, $n_skip skipped"
[[ $n_fail -eq 0 ]] || summary="$summary (failed: ${failed[*]})"
echo "$summary"
[[ $n_fail -eq 0 ]] || exit 1
exit 0
