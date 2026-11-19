#!/usr/bin/env bash
# check.sh - run the lint checks of CI on your machine: syntax, ShellCheck, --help, site data,
# design tokens, the quick tests, the committed-file guard and the docs linters (actionlint, yamllint,
# markdownlint-cli2, lychee). It runs the checks of .github/workflows/lint.yml, with ShellCheck pinned
# to 0.11.0 (CI may use another ShellCheck version until lint.yml runs this script), and the docs
# checks, which no CI job runs yet (see the docs section below). It never calls sudo, needs no root
# and changes nothing on the system.
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
#   security      scripts/check-files.sh: no report, filled config, key or CLAUDE.local.md is tracked,
#                 every IPv4 address is an example (needs git and .git; reads the staged copy: run it after
#                 git add)
#   docs          actionlint (with ShellCheck on the run: blocks) on .github/workflows/, yamllint on
#                 .github/, markdownlint-cli2 and lychee --offline (relative links and anchors) on the
#                 Markdown files (needs yamllint and markdownlint-cli2). External links are never
#                 checked here. No CI job runs this section yet: the docs workflow of #39 is still to
#                 be added (see section_docs).
#
# Pinned tools: ShellCheck 0.11.0 (lint, and actionlint in docs), actionlint 1.7.12 and lychee 0.24.2
# (docs). A copy on PATH is used only when it is that version. Otherwise the release archive for your
# system is downloaded once to ${XDG_CACHE_HOME:-~/.cache}/server-prep/, when a section that needs it
# runs. Its SHA-256 is checked on every run, then the tool is unpacked into a temporary folder and run
# from there. A checksum mismatch stops the script. yamllint and markdownlint-cli2 are not downloaded:
# install yamllint 1.38.0 and markdownlint-cli2 0.24.0 (Node 22 or later), the versions the docs
# workflow of #39 is to install.
#
# Needs bash 5, curl, tar and sha256sum (or shasum on macOS). Some sections also need jq, ssh-keygen,
# unzip, python3, git, yamllint and markdownlint-cli2 (see the list above). When one is missing, the
# sections that need it show SKIP on your machine (docs also prints how to install its tools); CI has
# them all, and there a missing one is a FAIL. The same goes for .git: without it (a release tarball)
# security shows SKIP, and with CI=true it is a FAIL.
# Linux is the reference platform (CI runs ubuntu-latest). On macOS, syntax, lint and help match
# CI; the other sections may need the GNU tools.
#
# Exit status: 0 every section passed or was skipped, 1 a section failed, 2 a usage error, bash
# older than 5, or a pinned tool that cannot be downloaded or fails its checksum.
#
# Add a section (tests #37): one line in SECTIONS and one section_<name> function (a dash in the
# name becomes an underscore). A prepare_<name> function, when there is one, runs first, outside the
# section's log: it fetches the pinned tools the section needs.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then echo "bash 5 needed (macOS: brew install bash)" >&2; exit 2; fi
set -euo pipefail
export LC_ALL=C
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Pinned tools, downloaded on first use and never bundled. Update a version and its four hashes
# together. The hashes are the SHA-256 of the release .tar.gz assets, shown on the GitHub release page
# (actionlint also lists them in its checksums.txt, lychee in a .sha256 file per asset). Keys: the
# os.arch that platform prints.
# ShellCheck (https://github.com/koalaman/shellcheck, GPL-3.0): the lint section, and actionlint in docs.
SHELLCHECK_VERSION="0.11.0"
declare -A SHELLCHECK_SHA256=(
    [linux.x86_64]="b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6"
    [linux.aarch64]="68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc"
    [darwin.x86_64]="c2c15e08df0e8fbc374c335b230a7ee958c313fa5714817a59aa59f1aa594f51"
    [darwin.aarch64]="339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f"
)
# actionlint (https://github.com/rhysd/actionlint, MIT): the docs section.
ACTIONLINT_VERSION="1.7.12"
declare -A ACTIONLINT_SHA256=(
    [linux.x86_64]="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
    [linux.aarch64]="325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6"
    [darwin.x86_64]="5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644"
    [darwin.aarch64]="aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f"
)
declare -A ACTIONLINT_ASSET=(   # the os_arch part of the asset name
    [linux.x86_64]="linux_amd64" [linux.aarch64]="linux_arm64"
    [darwin.x86_64]="darwin_amd64" [darwin.aarch64]="darwin_arm64"
)
# lychee (https://github.com/lycheeverse/lychee, Apache-2.0 or MIT): the docs section. The static
# musl builds on Linux.
LYCHEE_VERSION="0.24.2"
declare -A LYCHEE_SHA256=(
    [linux.x86_64]="73657a111819a30c47c08352896796f23d64e4eb2b3ed39b6d32149241566fc5"
    [linux.aarch64]="5d0b0e3aeab240f41920c633a6eaf97599be6eedda034b36e858ede7dba5e535"
    [darwin.x86_64]="887503a9cff667d322b8d0892b40bf49976eb9507af8483220a3706cdad55978"
    [darwin.aarch64]="c9d3740ea2d891854d37116c9fba840f37b6e7c89d330e7db84ac333631c4977"
)
declare -A LYCHEE_TARGET=(   # the target part of the asset name
    [linux.x86_64]="x86_64-unknown-linux-musl" [linux.aarch64]="aarch64-unknown-linux-musl"
    [darwin.x86_64]="x86_64-apple-darwin" [darwin.aarch64]="aarch64-apple-darwin"
)
# The docs section's other tools are not downloaded: install them (INSTALL_HINT shows how when one
# is missing). The docs workflow of #39 is to install these versions; the docs section names any
# other version it runs.
YAMLLINT_VERSION="1.38.0"
MARKDOWNLINT_CLI2_VERSION="0.24.0"
declare -A INSTALL_HINT=(
    [yamllint]="pipx install yamllint==$YAMLLINT_VERSION"
    [markdownlint-cli2]="npm install -g markdownlint-cli2@$MARKDOWNLINT_CLI2_VERSION (Node 22 or later)"
)
# Sections that no CI job runs yet: their SKIP line says so, not "CI runs this check". Remove docs
# once the docs workflow of #39 is added.
declare -A NO_CI_JOB=([docs]=1)
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/server-prep"

# The files of the Syntax and ShellCheck steps of .github/workflows/lint.yml, in the same order.
# The Lint step of .github/workflows/release.yml checks a part of them. Keep the three lists in
# sync until both workflows run this script. No nullglob, as in lint.yml: when a folder is gone,
# its pattern stays as written and the syntax and lint sections fail on it, instead of checking
# fewer files without a word.
FILES=(server-prep.sh server-audit.sh server-preconfig.sh extras/github-runners/*.sh scripts/*.sh tests/*.sh tests/e2e/*.sh tests/e2e/lib/*.sh)
HELP_SCRIPTS=(server-prep.sh server-preconfig.sh server-audit.sh)

# One line per section, in run order: name|gate|tools|description
#   gate: a file the section needs; when it is missing, the section is skipped, in CI too (a script
#         still to come). "ci:<file>": skipped only on your machine; with CI=true a missing file is a
#         FAIL, as a missing tool is (.git: a release tarball has none, a CI checkout must). "-": always
#         runs (a missing file is then a FAIL, as in CI).
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
    "security|ci:.git|git|no forbidden file is tracked, every IPv4 address is an example (scripts/check-files.sh)"
    "docs|-|yamllint markdownlint-cli2|actionlint on the workflows, yamllint on .github/, markdownlint-cli2 and lychee --offline (relative links and anchors) on the Markdown files"
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
            if [[ -e ${gate#ci:} ]]; then state=present; else state=missing; fi
            desc="$desc; runs when ${gate#ci:} exists ($state)"
            [[ $gate != ci:* ]] || desc="$desc, fails in CI without it"
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

# --- Pinned tools ------------------------------------------------------------

sha256_of() {   # prints the SHA-256 of a file
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}

platform() {   # prints the key of the pinned hashes: linux.x86_64, linux.aarch64, darwin.x86_64, darwin.aarch64
    local os arch
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
    echo "$os.$arch"
}

# fetch_pinned NAME VERSION URL SHA256 ARCHIVE MEMBER: sets FETCHED to MEMBER of the release archive
# at URL, unpacked into its own folder under $WORK. The archive is downloaded once to
# $CACHE_DIR/ARCHIVE (https only, size capped, to a temporary file renamed once its SHA-256 matches),
# and the copy unpacked here is checked again on every run. Stops with exit 2 when it cannot. Never
# call it in $(...): die would only end the subshell, and DOWNLOAD_TMP must reach the EXIT trap.
fetch_pinned() {
    local name="$1" v="$2" url="$3" want="$4" archive="$CACHE_DIR/$5" member="$6" dir tmp got
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
        || die "sha256sum or shasum needed to check $name: install coreutils, or install $name $v on PATH"
    command -v tar >/dev/null 2>&1 || die "tar needed to unpack $name: install tar, or install $name $v on PATH"

    if [[ ! -f $archive ]]; then
        command -v curl >/dev/null 2>&1 || die "curl needed to download $name $v: install curl, or install $name $v on PATH"
        mkdir -p "$CACHE_DIR"
        echo "Downloading $name $v ($(platform | tr . ' ')) to $CACHE_DIR"
        # a temporary file in the same folder, renamed once checked: an interrupted or concurrent
        # run never leaves a partial archive under the trusted name
        tmp="$(mktemp "$CACHE_DIR/.${name,,}-download.XXXXXX")"
        DOWNLOAD_TMP="$tmp"
        if ! curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize 33554432 --retry 3 \
                --connect-timeout 20 -o "$tmp" "$url"; then
            rm -f "$tmp"
            die "could not download $name $v ($url): check the network, or install $name $v on PATH; other sections still run with --only <section>"
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
    dir="$WORK/${name,,}"
    mkdir -p "$dir"
    cp "$archive" "$dir/archive.tar.gz"
    got="$(sha256_of "$dir/archive.tar.gz")"
    [[ $got == "$want" ]] \
        || die "cached $archive fails its SHA-256 check (expected $want, got $got): delete it and run again to download it again"
    tar -xzf "$dir/archive.tar.gz" -C "$dir" "$member" \
        || die "could not unpack $member from $archive"
    FETCHED="$dir/$member"
}

# Each find_<tool> sets its variable (SHELLCHECK, ACTIONLINT, LYCHEE) to the pinned version: the copy
# on PATH when it is that version, otherwise the pinned release from the cache (fetch_pinned). Stops
# with exit 2 when there is none.
find_shellcheck() {
    local v="$SHELLCHECK_VERSION" path_version key want
    if command -v shellcheck >/dev/null 2>&1; then
        path_version="$(shellcheck --version 2>/dev/null | sed -n 2p)" || path_version=""
        if [[ $path_version == "version: $v" ]]; then
            SHELLCHECK="$(command -v shellcheck)"
            return 0
        fi
        path_version="${path_version#version: }"
        echo "shellcheck on PATH is version ${path_version:-unknown}, not $v: using the pinned ShellCheck $v"
    fi
    key="$(platform)"
    want="${SHELLCHECK_SHA256[$key]:-}"
    [[ -n $want ]] || die "no pinned ShellCheck for ${key/./ }: install ShellCheck $v on PATH"
    fetch_pinned ShellCheck "$v" "https://github.com/koalaman/shellcheck/releases/download/v$v/shellcheck-v$v.$key.tar.gz" \
        "$want" "shellcheck-v$v.$key.tar.gz" "shellcheck-v$v/shellcheck"
    SHELLCHECK="$FETCHED"
}

find_actionlint() {
    local v="$ACTIONLINT_VERSION" path_version key want asset
    if command -v actionlint >/dev/null 2>&1; then
        path_version="$(actionlint -version 2>/dev/null | sed -n 1p)" || path_version=""
        if [[ $path_version == "$v" ]]; then
            ACTIONLINT="$(command -v actionlint)"
            return 0
        fi
        echo "actionlint on PATH is version ${path_version:-unknown}, not $v: using the pinned actionlint $v"
    fi
    key="$(platform)"
    want="${ACTIONLINT_SHA256[$key]:-}"
    [[ -n $want ]] || die "no pinned actionlint for ${key/./ }: install actionlint $v on PATH"
    asset="actionlint_${v}_${ACTIONLINT_ASSET[$key]}.tar.gz"
    fetch_pinned actionlint "$v" "https://github.com/rhysd/actionlint/releases/download/v$v/$asset" \
        "$want" "$asset" actionlint
    ACTIONLINT="$FETCHED"
}

find_lychee() {
    local v="$LYCHEE_VERSION" path_version key want target
    if command -v lychee >/dev/null 2>&1; then
        path_version="$(lychee --version 2>/dev/null | sed -n 1p)" || path_version=""
        if [[ $path_version == "lychee $v" ]]; then
            LYCHEE="$(command -v lychee)"
            return 0
        fi
        path_version="${path_version#lychee }"
        echo "lychee on PATH is version ${path_version:-unknown}, not $v: using the pinned lychee $v"
    fi
    key="$(platform)"
    want="${LYCHEE_SHA256[$key]:-}"
    [[ -n $want ]] || die "no pinned lychee for ${key/./ }: install lychee $v on PATH"
    target="${LYCHEE_TARGET[$key]}"
    fetch_pinned lychee "$v" "https://github.com/lycheeverse/lychee/releases/download/lychee-v$v/lychee-$target.tar.gz" \
        "$want" "lychee-v$v.$target.tar.gz" "lychee-$target/lychee"
    LYCHEE="$FETCHED"
}

# prepare_<section> runs before section_<section>, outside its log (see the main loop).
prepare_docs() {
    [[ -n $SHELLCHECK ]] || find_shellcheck
    find_actionlint
    find_lychee
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

section_security() {
    local rc=0
    DETAIL="scripts/check-files.sh, on the staged copy"
    bash scripts/check-files.sh || rc=$?
    if [[ $rc -eq 1 ]]; then
        echo "It reads the staged copy: stage your fix before running the check again."
    fi
    return "$rc"
}

# lychee runs offline: only relative links and their anchors, so a dead external link never fails
# this section. No CI job runs this section yet. The docs workflow of #39, still to be added by a
# maintainer, is to run `CI=true ./scripts/check.sh --only docs` on pull requests and pushes to main
# (with yamllint and markdownlint-cli2 at the versions above), and the online link check of
# lychee.toml once a week.
section_docs() {
    local rc=0 yl ml
    yl="$(yamllint --version 2>&1)" || yl="yamllint"
    [[ $yl == "yamllint $YAMLLINT_VERSION" ]] || yl="$yl (expected: $YAMLLINT_VERSION)"
    ml="$(markdownlint-cli2 --help 2>&1 | sed -n 1p || true)"   # "markdownlint-cli2 vX (markdownlint vY)"; --help may exit non-zero
    [[ "$ml " == "markdownlint-cli2 v$MARKDOWNLINT_CLI2_VERSION "* ]] || ml="${ml:-markdownlint-cli2} (expected: $MARKDOWNLINT_CLI2_VERSION)"
    DETAIL="actionlint $ACTIONLINT_VERSION, $yl, $ml, lychee $LYCHEE_VERSION offline"

    echo "--- actionlint (ShellCheck on the run: blocks)"
    "$ACTIONLINT" -shellcheck "$SHELLCHECK" -pyflakes= .github/workflows/*.yml || rc=1
    echo "--- yamllint"
    yamllint --strict -c .yamllint.yml .github || rc=1
    echo "--- markdownlint-cli2"
    markdownlint-cli2 '**/*.md' || rc=1
    echo "--- lychee --offline"
    "$LYCHEE" --config lychee.toml --offline --include-fragments --no-progress '**/*.md' || rc=1
    return "$rc"
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
ACTIONLINT=""
LYCHEE=""
FETCHED=""
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

    if [[ $gate != - && ! -e ${gate#ci:} ]]; then
        if [[ $gate == ci:* && ${CI:-} == true ]]; then
            line FAIL "$name" "${gate#ci:} not found (CI needs it)"
            n_fail=$((n_fail + 1))
            failed+=("$name")
        else
            line SKIP "$name" "${gate#ci:} not found"
            n_skip=$((n_skip + 1))
        fi
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
            it=it
            [[ ${#missing[@]} -eq 1 ]] || it=them
            ci_note="CI runs this check"
            [[ -z ${NO_CI_JOB[$name]:-} ]] || ci_note="no CI job runs it yet"
            line SKIP "$name" "needs ${missing[*]} (install $it; $ci_note)"
            n_skip=$((n_skip + 1))
        fi
        for tool in "${missing[@]}"; do
            [[ -z ${INSTALL_HINT[$tool]:-} ]] || printf '%6s%s: %s\n' '' "$tool" "${INSTALL_HINT[$tool]}"
        done
        continue
    fi

    # The section's pinned tools, outside its log: a download or checksum failure stops the script
    # (exit 2) with its message on the terminal, as for ShellCheck above.
    if declare -F "prepare_${name//-/_}" >/dev/null; then
        "prepare_${name//-/_}"
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
