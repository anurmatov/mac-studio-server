#!/bin/sh
# bootstrap.sh — one-line installer for mac-studio-server (#15).
#
#   curl -fsSL https://raw.githubusercontent.com/anurmatov/mac-studio-server/v1.5.0/bootstrap.sh | sh
#   ... | sh -s -- --ref <40-hex commit>        (testing a specific commit)
#
# Clones or updates ~/mac-studio-server (MSS_DIR) at the release tag, checks the
# clone matches what GitHub serves for that ref, then hands off to
# scripts/install.sh on the terminal. Nothing runs until the last line calls
# main, so a truncated download does nothing. Prompts are read from /dev/tty,
# never from the pipe.

MSS_TAG=v1.5.0
MSSB_REMOTE=https://github.com/anurmatov/mac-studio-server.git
MSSB_RAW=https://raw.githubusercontent.com/anurmatov/mac-studio-server

mssb_say() { echo "$*" >&2; }
mssb_die() { echo "bootstrap: $*" >&2; exit 1; }

# mssb_yn <prompt>: default N; reads the terminal.
mssb_yn() {
    printf '%s [y/N]: ' "$1" >&2
    IFS= read -r mssb_answer </dev/tty || mssb_answer=""
    case $mssb_answer in [Yy]|[Yy][Ee][Ss]) return 0 ;; esac
    return 1
}

# U1 for the bootstrap: one prompt, then keep sudo alive while this PID runs
# (it survives the exec into install.sh, which drops traps).
mssb_sudo() {
    sudo -v -p '[sudo] password (asked once): ' </dev/tty || mssb_die "sudo failed; nothing was changed"
    mssb_pid=$$
    ( while kill -0 "$mssb_pid" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) >/dev/null 2>&1 &
}

# B3: the Command Line Tools provide git. The headless vendor method Homebrew uses.
mssb_clt() {
    "${MSS_XCODE_SELECT:-xcode-select}" -p >/dev/null 2>&1 && return 0
    if mssb_yn "Install Xcode Command Line Tools (needed for git)?"; then
        mssb_sudo
        mssb_marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        touch "$mssb_marker"
        mssb_label=$(softwareupdate -l 2>/dev/null \
            | sed -n 's/^[[:space:]]*\*[[:space:]]*Label:[[:space:]]*\(Command Line Tools.*\)$/\1/p' | sort -V | tail -n 1)
        if [ -n "$mssb_label" ]; then
            mssb_say "installing $mssb_label"
            sudo softwareupdate -i "$mssb_label" >&2
        fi
        rm -f "$mssb_marker"
        "${MSS_XCODE_SELECT:-xcode-select}" -p >/dev/null 2>&1 && return 0
    fi
    mssb_say "xcode-select --install"
    mssb_say "then re-run this command"
    exit 1
}

# mssb_ref_valid <ref>: the embedded tag, or a full 40-hex commit.
mssb_ref_valid() {
    [ "$1" = "$MSS_TAG" ] && return 0
    printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

# mssb_verify <ref> <candidate bootstrap.sh> <commit> (B5): the candidate must be
# byte-identical to what raw.githubusercontent.com serves for <ref>, carry this
# script's MSS_TAG line, and <commit> must be the ref (for a sha). Prints why not.
# MSSB_CURL replaces /usr/bin/curl in the phase A fixture tests only.
mssb_verify() {
    mssb_vref=$1 mssb_vfile=$2 mssb_vcommit=$3
    mssb_ref_valid "$mssb_vref" || { mssb_say "refusing ref '$mssb_vref': use $MSS_TAG or a full 40-hex commit"; return 1; }
    case $mssb_vref in
        "$MSS_TAG") ;;
        *) [ "$mssb_vcommit" = "$mssb_vref" ] || { mssb_say "the clone is at $mssb_vcommit, not $mssb_vref"; return 1; } ;;
    esac
    [ "$(grep -m 1 '^MSS_TAG=' "$mssb_vfile")" = "MSS_TAG=$MSS_TAG" ] \
        || { mssb_say "the clone's MSS_TAG line differs from this script's ($MSS_TAG)"; return 1; }
    mssb_raw=$(mktemp "${TMPDIR:-/tmp}/mss-bootstrap.XXXXXX") || return 1
    if ! "${MSSB_CURL:-/usr/bin/curl}" -fsSL --proto '=https' --proto-redir '=https' \
        -o "$mssb_raw" "$MSSB_RAW/$mssb_vref/bootstrap.sh"; then
        rm -f "$mssb_raw"
        mssb_say "cannot fetch $MSSB_RAW/$mssb_vref/bootstrap.sh"
        return 1
    fi
    if ! cmp -s "$mssb_raw" "$mssb_vfile"; then
        rm -f "$mssb_raw"
        mssb_say "bootstrap.sh in the clone differs from the one GitHub serves for $mssb_vref"
        return 1
    fi
    rm -f "$mssb_raw"
    return 0
}

# mssb_fetch <dir> <ref>: fetch the ref into an existing clone without moving it.
# Prints the commit to check out.
mssb_fetch() {
    if [ "$2" = "$MSS_TAG" ]; then
        git -C "$1" fetch --quiet --depth 1 origin "refs/tags/$2:refs/tags/$2" >&2 || return 1
        git -C "$1" rev-parse "refs/tags/$2^{commit}"
    else
        git -C "$1" fetch --quiet --depth 1 origin "$2" >&2 || return 1
        git -C "$1" rev-parse FETCH_HEAD
    fi
}

main() {
    mssb_ref=$MSS_TAG
    while [ $# -gt 0 ]; do
        case $1 in
            --ref) [ $# -ge 2 ] || mssb_die "--ref needs a 40-hex commit"; mssb_ref=$2; shift 2 ;;
            *) mssb_die "unknown argument '$1' (only --ref <40-hex commit>)" ;;
        esac
    done

    # B1: prompts come from the terminal; without one, say how to install by hand.
    if ! { : </dev/tty; } 2>/dev/null; then
        echo "no terminal: git clone $MSSB_REMOTE && cd mac-studio-server && ./scripts/install.sh" >&2
        exit 1
    fi
    # B2
    [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || mssb_die "mac-studio-server needs macOS on Apple silicon"
    mssb_ref_valid "$mssb_ref" || mssb_die "refusing ref '$mssb_ref': use $MSS_TAG or a full 40-hex commit"
    # B3
    mssb_clt

    # B4: clone into a temporary sibling, or update a clean clone of this repo.
    mssb_dir=${MSS_DIR:-$HOME/mac-studio-server}
    if [ -e "$mssb_dir" ] || [ -L "$mssb_dir" ]; then
        [ -d "$mssb_dir/.git" ] && [ ! -L "$mssb_dir" ] || mssb_die "$mssb_dir exists and is not a mac-studio-server clone; left untouched"
        [ "$(git -C "$mssb_dir" remote get-url origin 2>/dev/null)" = "$MSSB_REMOTE" ] \
            || mssb_die "$mssb_dir is not a clone of $MSSB_REMOTE; left untouched"
        [ -z "$(git -C "$mssb_dir" status --porcelain --untracked-files=no 2>/dev/null)" ] \
            || mssb_die "$mssb_dir has modified files; left untouched"
        mssb_prev=$(git -C "$mssb_dir" rev-parse HEAD) || mssb_die "$mssb_dir has no commit; left untouched"
        mssb_commit=$(mssb_fetch "$mssb_dir" "$mssb_ref") || mssb_die "cannot fetch $mssb_ref; $mssb_dir is unchanged"
        mssb_cand=$(mktemp "${TMPDIR:-/tmp}/mss-candidate.XXXXXX") || exit 1
        git -C "$mssb_dir" show "$mssb_commit:bootstrap.sh" > "$mssb_cand" 2>/dev/null \
            || { rm -f "$mssb_cand"; mssb_die "$mssb_ref has no bootstrap.sh; $mssb_dir is unchanged"; }
        if ! mssb_verify "$mssb_ref" "$mssb_cand" "$mssb_commit"; then
            rm -f "$mssb_cand"
            mssb_die "verification failed; $mssb_dir is unchanged"
        fi
        rm -f "$mssb_cand"
        if [ "$mssb_ref" = "$MSS_TAG" ]; then
            git -C "$mssb_dir" checkout --quiet --detach "refs/tags/$mssb_ref" || mssb_die "checkout failed"
        else
            git -C "$mssb_dir" checkout --quiet --detach "$mssb_commit" || mssb_die "checkout failed"
        fi
    else
        mssb_new=$(mktemp -d "$(dirname "$mssb_dir")/.mss-clone.XXXXXX") || mssb_die "cannot create a directory next to $mssb_dir"
        if [ "$mssb_ref" = "$MSS_TAG" ]; then
            git clone --quiet --depth 1 --branch "$mssb_ref" "$MSSB_REMOTE" "$mssb_new/repo" >&2 \
                || { rm -rf "$mssb_new"; mssb_die "cannot clone $mssb_ref"; }
        else
            { git init --quiet "$mssb_new/repo" && git -C "$mssb_new/repo" remote add origin "$MSSB_REMOTE" \
                && git -C "$mssb_new/repo" fetch --quiet --depth 1 origin "$mssb_ref" \
                && git -C "$mssb_new/repo" checkout --quiet --detach FETCH_HEAD; } >&2 \
                || { rm -rf "$mssb_new"; mssb_die "cannot fetch $mssb_ref"; }
        fi
        mssb_commit=$(git -C "$mssb_new/repo" rev-parse HEAD)
        if ! mssb_verify "$mssb_ref" "$mssb_new/repo/bootstrap.sh" "$mssb_commit"; then
            rm -rf "$mssb_new"
            mssb_die "verification failed; nothing was installed"
        fi
        mv "$mssb_new/repo" "$mssb_dir" || { rm -rf "$mssb_new"; mssb_die "cannot create $mssb_dir"; }
        rm -rf "$mssb_new"
    fi

    # B5, after checkout: HEAD is exactly the ref.
    mssb_head=$(git -C "$mssb_dir" rev-parse HEAD)
    if [ "$mssb_ref" = "$MSS_TAG" ]; then
        [ "$(git -C "$mssb_dir" describe --exact-match --tags 2>/dev/null)" = "$MSS_TAG" ] || {
            [ -z "${mssb_prev:-}" ] || git -C "$mssb_dir" checkout --quiet --detach "$mssb_prev"
            mssb_die "HEAD is not $MSS_TAG"
        }
    else
        [ "$mssb_head" = "$mssb_ref" ] || {
            [ -z "${mssb_prev:-}" ] || git -C "$mssb_dir" checkout --quiet --detach "$mssb_prev"
            mssb_die "HEAD is not $mssb_ref"
        }
    fi
    mssb_say "mac-studio-server $mssb_ref at commit $mssb_head in $mssb_dir"

    # B6: hand off on the terminal.
    exec /bin/bash "$mssb_dir/scripts/install.sh" </dev/tty
}

main "$@"
