#!/bin/sh
# mss-host.sh — host-level choices shared by Ollama, llama.cpp and ds4 (#27):
# the choice resolver, its validation, and the GPU / Docker-autostart / power
# apply steps, with read-only classifiers for the picker summary and status.sh.
#
# POSIX sh. Sources after mss-common.sh; mss_choices_validate additionally
# needs mss-acquire.sh sourced (Homebrew detection). Callers set REPO_DIR.
#
# Test hooks (D4c):
#   launchctl and plutil   called by name, so phase A puts stubs first on PATH
#   sysctl and pmset       /usr/sbin/sysctl and /usr/bin/pmset by absolute path;
#                          MSS_SYSCTL / MSS_PMSET replace them only inside a test
#                          sysroot (mss_wired_limit_mb in mss-common.sh still
#                          reads hw.memsize through `sysctl` by name)
#   privileged calls       ${MSS_SUDO:-sudo} (_mss_root)
#   plists                 ${MSS_TEST_SYSROOT:-}/Library/LaunchDaemons
#   MSS_DOCKER_JOB_PATH    the boot job's PATH, which is what "installed" means
#                          for colima and the Docker CLI

# The boot job com.colima.daemon runs with this PATH; a tool found only
# elsewhere would install fine and fail at boot, so both `yes` values refuse it.
MSS_DOCKER_JOB_PATH=${MSS_DOCKER_JOB_PATH:-/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin}

MSS_GPU_LABEL="com.mac-studio-server.gpumemory"
MSS_GPU_LABEL_LEGACY="com.ollama.gpumemory"
MSS_DOCKER_LABEL="com.colima.daemon"

mss_daemon_dir() { printf '%s/Library/LaunchDaemons\n' "${MSS_TEST_SYSROOT:-}"; }

# _mss_root <cmd...>: the one place a privileged call happens. A root pass runs
# the command directly; anyone else goes through the sudo named by MSS_SUDO (the
# real installer leaves it unset, so that is plain sudo).
#
# D4c says every privileged call must be stubbable, and the root short-circuit
# is what makes that safe rather than merely convenient: a phase A pass that
# exports MSS_SUDO asks for the shim even when it happens to be root, and
# without it the stubs named by MSS_PMSET/MSS_SYSCTL/PATH would be bypassed
# while `rm -f` and `mv -f` really deleted the plists under the test sysroot.
# The shim tests/run.sh installs runs its arguments as the calling user, so an
# exported MSS_SUDO on a root pass can only ever run commands that user could
# already run — it is a downgrade, never an escalation.
_mss_root() {
    if [ "$(id -u)" = 0 ] && [ -z "${MSS_SUDO:-}" ]; then "$@"; else ${MSS_SUDO:-sudo} "$@"; fi
}

# The system binaries are named by absolute path so a hostile PATH cannot
# replace them, and a test hook is honoured only inside a test sysroot. The
# lookup happens before _mss_root sees the command, so a stub stays a stub
# through the sudo shim.
# _mss_bin_hook: a test hook exported in the environment is honoured only inside
# a test sysroot. Outside one every call uses the absolute system binary, so a
# stray or inherited MSS_SYSCTL / MSS_PMSET can never redirect a privileged call
# on a real Mac (#27 r2, security).
#   _mss_bin_hook MSS_SYSCTL /usr/sbin/sysctl   -> sets $_mss_bin
_mss_bin_hook() {
    _mss_bin=${2:-}
    [ -n "${MSS_TEST_SYSROOT:-}" ] || return 0
    _mss_hooked=$(printenv "${1:-}" 2>/dev/null) || return 0
    [ -n "$_mss_hooked" ] || return 0
    _mss_bin=$_mss_hooked
}
_mss_sysctl() { _mss_bin_hook MSS_SYSCTL /usr/sbin/sysctl; "$_mss_bin" "$@"; }
_mss_pmset() { _mss_bin_hook MSS_PMSET /usr/bin/pmset; "$_mss_bin" "$@"; }

# ── D1 resolver: legacy keys in, new keys out, before any question or change ──
_mss_choice_source() {
    case " ${MSS_ENVFILE_LOADED:-} " in *" $1 "*) echo "backends.env" ;; *) echo "environment" ;; esac
}

# mss_choices_resolve: map OLLAMA_GPU_PERCENT onto MSS_GPU_PERCENT and
# DOCKER_AUTOSTART onto MSS_DOCKER_AUTOSTART. A conflict exits 1 before any
# change; each deprecation notice prints once per run; the legacy GPU key is
# unset afterwards so only MSS_GPU_PERCENT reaches the picker, writer and jobs.
mss_choices_resolve() {
    if [ "${MSS_CHOICES_RESOLVED:-}" = 1 ]; then
        # Idempotent: the notices already printed; re-check nothing.
        unset DOCKER_AUTOSTART OLLAMA_GPU_PERCENT
        return 0
    fi
    _new=${MSS_GPU_PERCENT:-}; _old=${OLLAMA_GPU_PERCENT:-}
    unset OLLAMA_GPU_PERCENT
    if [ -n "$_old" ]; then
        if [ -n "$_new" ] && [ "$_new" != "$_old" ]; then
            mss_error "MSS_GPU_PERCENT=$_new ($(_mss_choice_source MSS_GPU_PERCENT)) and OLLAMA_GPU_PERCENT=$_old ($(_mss_choice_source OLLAMA_GPU_PERCENT)) differ; keep one"
            return 1
        fi
        case $(_mss_choice_source OLLAMA_GPU_PERCENT) in
            backends.env)
                echo "OLLAMA_GPU_PERCENT is deprecated; using it as MSS_GPU_PERCENT=$_old. Rename it in backends.env (install.sh --configure does this)." >&2 ;;
            *)
                echo "OLLAMA_GPU_PERCENT is deprecated; using it as MSS_GPU_PERCENT=$_old. Set MSS_GPU_PERCENT instead." >&2 ;;
        esac
        MSS_GPU_PERCENT=$_old
        export MSS_GPU_PERCENT
    fi
    case ${DOCKER_AUTOSTART:-} in
        '') ;;
        true)
            if [ "${MSS_DOCKER_AUTOSTART:-}" = no ]; then
                mss_error "DOCKER_AUTOSTART=true and MSS_DOCKER_AUTOSTART=no conflict; keep one"
                return 1
            fi
            echo "DOCKER_AUTOSTART=true is deprecated; setting MSS_DOCKER_AUTOSTART=yes." >&2
            export MSS_DOCKER_AUTOSTART=yes
            [ -n "${MSS_DOCKER_INSTALL:-}" ] || export MSS_DOCKER_INSTALL=yes
            ;;
        false)
            echo "DOCKER_AUTOSTART=false is ignored; use MSS_DOCKER_AUTOSTART=yes or no." >&2 ;;
        *)
            mss_error "DOCKER_AUTOSTART is replaced by MSS_DOCKER_AUTOSTART=yes or no"
            return 1 ;;
    esac
    # The legacy GPU key is read but never honoured after this point: leaving
    # it exported would trip install-backends.sh's guard on a direct run (#27).
    unset DOCKER_AUTOSTART OLLAMA_GPU_PERCENT
    MSS_CHOICES_RESOLVED=1
    return 0
}

# ── validation, after resolution and before any change ─────────────────────────
# mss_choices_check_format: the format checks only — model.sh runs these and
# never probes Docker, Homebrew or pmset, because it never applies them.
mss_choices_check_format() {
    _g=${MSS_GPU_PERCENT:-}
    case $_g in
        ''|system) ;;
        *)
            mss_match "$_g" '^[1-9][0-9]{0,2}$' \
                || { mss_error "MSS_GPU_PERCENT: '$_g' must be 1-100 or system (no leading zeros)"; return 1; }
            [ "$_g" -le 100 ] || { mss_error "MSS_GPU_PERCENT: '$_g' is above 100"; return 1; }
            _mss_sysctl -n iogpu.wired_limit_mb >/dev/null 2>&1 \
                || { mss_error "this Mac has no iogpu.wired_limit_mb; use MSS_GPU_PERCENT=system"; return 1; }
            _mss_sysctl -n hw.memsize >/dev/null 2>&1 \
                || { mss_error "cannot read hw.memsize; MSS_GPU_PERCENT=$_g cannot be applied"; return 1; }
            ;;
    esac
    for _k in MSS_DOCKER_INSTALL MSS_DOCKER_AUTOSTART MSS_POWER_AUTORESTART; do
        case $(printenv "$_k") in
            ''|yes|no) ;;
            *) mss_error "$_k must be yes or no"; return 1 ;;
        esac
    done
    return 0
}

# _mss_job_tool <tool>: is the tool on the boot job's PATH? The boot job runs
# with MSS_DOCKER_JOB_PATH and nothing else, so "installed" means found *there*
# — appending $PATH would report a tool the daemon cannot reach at boot. The
# #21 guard forbids a `PATH=…` prefix assignment that drops $PATH; a scoped
# subshell export is the honest form of the same lookup.
_mss_job_tool() { ( PATH="$MSS_DOCKER_JOB_PATH"; export PATH; command -v "$1" 2>/dev/null ); }
_mss_docker_missing() { [ -n "$(_mss_job_tool colima)" ] && [ -n "$(_mss_job_tool docker)" ] && return 1; return 0; }

# _mss_docker_outside_job_path: "<tool> <path>" for a tool the caller can run but
# the boot job cannot, and rc 0; rc 1 when every Docker choice is appliable.
# The picker and the validator both need this: a tool outside the job PATH makes
# a saved MSS_DOCKER_INSTALL=yes or MSS_DOCKER_AUTOSTART=yes something step 2
# refuses on every later run, so the picker must not ask about Docker at all
# (#27 r2 finding 1).
_mss_docker_outside_job_path() {
    for _ot in colima docker; do
        [ -n "$(_mss_job_tool "$_ot")" ] && continue
        _ot_here=$(command -v "$_ot" 2>/dev/null) || continue
        [ -z "$_ot_here" ] || { printf '%s %s\n' "$_ot" "$_ot_here"; return 0; }
    done
    return 1
}

# mss_choices_validate: the full D1 validation (install.sh, before any change).
mss_choices_validate() {
    mss_choices_check_format || return 1
    _di=${MSS_DOCKER_INSTALL:-}; _da=${MSS_DOCKER_AUTOSTART:-}
    if [ "$_di" = yes ] || [ "$_da" = yes ]; then
        _bad=$(_mss_docker_outside_job_path) || _bad=''
        [ -z "$_bad" ] || {
            mss_error "${_bad% *} is at ${_bad#* }, outside the boot job's PATH; move or link it into /opt/homebrew/bin or /usr/local/bin"
            return 1
        }
    fi
    if [ "$_di" = yes ] && _mss_docker_missing; then
        [ "$(id -u)" -ne 0 ] \
            || { mss_error "MSS_DOCKER_INSTALL=yes: run install.sh as your user; Homebrew refuses root"; return 1; }
        mss_brew >/dev/null \
            || { mss_error "MSS_DOCKER_INSTALL=yes needs Homebrew: $(mss_brew_install_cmd)"; return 1; }
    fi
    if [ "$_da" = yes ]; then
        if [ "$_di" != yes ] && _mss_docker_missing; then
            mss_error "MSS_DOCKER_AUTOSTART=yes needs Colima and the Docker CLI; set MSS_DOCKER_INSTALL=yes or install them"
            return 1
        fi
        if [ -z "${OLLAMA_USER:-}" ] && [ "$(id -u)" -eq 0 ]; then
            mss_error "MSS_DOCKER_AUTOSTART=yes needs a non-root user: run install.sh as your user or set OLLAMA_USER"
            return 1
        fi
    fi
    if [ -n "${MSS_POWER_AUTORESTART:-}" ]; then
        _mss_pmset -g 2>/dev/null | awk '$1=="autorestart"{found=1} END{exit !found}' \
            || { mss_error "this Mac has no restart-after-power-failure setting; unset MSS_POWER_AUTORESTART"; return 1; }
    fi
    return 0
}

# ── the root-pass guard (D4c) ──────────────────────────────────────────────────
# mss_host_root_guard: entry points call this after sourcing, exactly as
# install-backends.sh:55 does — a root pass must only ever see the real system,
# never a tests/run.sh sysroot.
mss_host_root_guard() {
    [ "$(id -u)" -ne 0 ] || [ -z "${MSS_TEST_SYSROOT:-}" ] \
        || mss_die "MSS_TEST_SYSROOT is for tests/run.sh only and is refused as root"
}

# ── D4 GPU boot job ─────────────────────────────────────────────────────────────
mss_gpu_plist_new() { printf '%s/%s.plist\n' "$(mss_daemon_dir)" "$MSS_GPU_LABEL"; }
mss_gpu_plist_legacy() { printf '%s/%s.plist\n' "$(mss_daemon_dir)" "$MSS_GPU_LABEL_LEGACY"; }

# mss_gpu_render <percent> <mb>: the new job. sysctl runs by absolute path from
# the plist itself (that is the plist content, not a lookup here).
mss_gpu_render() {
    sed -e "s|<GPU_PERCENT>|$1|" -e "s|<WIRED_LIMIT_MB>|$2|" \
        "$REPO_DIR/config/com.mac-studio-server.gpumemory.plist"
}

_mss_gpu_loaded() { launchctl print "system/$1" >/dev/null 2>&1; }
_mss_gpu_live_mb() { _mss_sysctl -n iogpu.wired_limit_mb 2>/dev/null; }

# mss_gpu_job_read: which GPU label is installed and the percent it records.
# Prints "<none|new|legacy|both>|<percent|unreadable>"; read-only, used by the
# picker default, the model.sh pre-check and status.sh.
mss_gpu_job_read() {
    _np=$(mss_gpu_plist_new); _lp=$(mss_gpu_plist_legacy)
    if [ -f "$_np" ] && [ -f "$_lp" ]; then
        _p=$(plutil -extract EnvironmentVariables.MSS_GPU_PERCENT raw "$_np" 2>/dev/null) \
            || _p=unreadable
        echo "both|$_p"
        return 0
    elif [ -f "$_np" ]; then
        _p=$(plutil -extract EnvironmentVariables.MSS_GPU_PERCENT raw "$_np" 2>/dev/null) \
            || _p=unreadable
        echo "new|$_p"
        return 0
    elif [ -f "$_lp" ]; then
        _p=$(plutil -extract EnvironmentVariables.OLLAMA_GPU_PERCENT raw "$_lp" 2>/dev/null) \
            || _p=unreadable
        echo "legacy|$_p"
        return 0
    else
        echo "none|"
    fi
}

# mss_gpu_job_precheck: a number needs the matching new job. model.sh runs it
# before any download, and again right before its save (D4b): the save and the
# backend install run after it, so the pre-save pass is what guards a write.
mss_gpu_job_precheck() {
    _g=${MSS_GPU_PERCENT:-}
    case $_g in ''|system) return 0 ;; esac
    _r=$(mss_gpu_job_read); _kind=${_r%%|*}; _rec=${_r#*|}
    case $_kind in
        new)
            [ "$_rec" != unreadable ] \
                || { mss_error "cannot read $MSS_GPU_LABEL; run scripts/install.sh"; return 1; }
            [ "$_rec" = "$_g" ] \
                || { mss_error "backends.env asks for MSS_GPU_PERCENT=$_g but the boot job applies $_rec; run scripts/install.sh first"; return 1; }
            return 0 ;;
        legacy)
            mss_error "the GPU memory boot job is still $MSS_GPU_LABEL_LEGACY; run scripts/install.sh first to migrate it"
            return 1 ;;
        both)
            mss_error "both $MSS_GPU_LABEL and $MSS_GPU_LABEL_LEGACY are installed; run scripts/install.sh first"
            return 1 ;;
        *)
            mss_error "MSS_GPU_PERCENT=$_g needs $MSS_GPU_LABEL; run scripts/install.sh first"
            return 1 ;;
    esac
}

# mss_gpu_legacy_note: the D9 status line for a machine that still has only the
# legacy job. Kept here with the other legacy messages (A9).
mss_gpu_legacy_note() {
    echo "$MSS_GPU_LABEL_LEGACY runs a user-editable script as root at boot; re-run install.sh with MSS_GPU_PERCENT to migrate"
}

# mss_gpu_jobs_remove (D10 and the `system` row): boot out and delete both GPU
# labels. Removing an absent plist makes no launchctl call and is not an error.
mss_gpu_jobs_remove() {
    for _l in "$MSS_GPU_LABEL" "$MSS_GPU_LABEL_LEGACY"; do
        case $_l in
            "$MSS_GPU_LABEL") _f=$(mss_gpu_plist_new) ;;
            *) _f=$(mss_gpu_plist_legacy) ;;
        esac
        [ -f "$_f" ] || continue
        _mss_root launchctl bootout "system/$_l" || true
        mss_launchd_wait_gone "$_l" "${MSS_LAUNCHD_TIMEOUT:-60}" || return 1
        _mss_root rm -f "$_f" || return 1
    done
    return 0
}

# _mss_gpu_plan <percent>: the read-only classification the apply step and the
# picker summary share. Prints one of: unchanged kickstart bootstrap boot left.
_mss_gpu_plan() {
    _g=${1:-}
    case $_g in
        '') if [ -f "$(mss_gpu_plist_legacy)" ]; then echo left-legacy; else echo left; fi; return ;;
        system) echo boot; return ;;
    esac
    _mb=$(mss_wired_limit_mb "$_g") || return 1
    _np=$(mss_gpu_plist_new)
    if [ -f "$_np" ] && mss_gpu_render "$_g" "$_mb" | cmp -s - "$_np" && _mss_gpu_loaded "$MSS_GPU_LABEL"; then
        if [ "$(_mss_gpu_live_mb)" = "$_mb" ]; then echo unchanged; else echo kickstart; fi
    else
        echo bootstrap
    fi
}

# _mss_gpu_remove_label <label> <plist>: bootout if loaded, wait, delete. An
# absent plist is a no-op with no launchctl call.
_mss_gpu_remove_label() {
    [ -f "$2" ] || return 0
    _mss_root launchctl bootout "system/$1" || true
    mss_launchd_wait_gone "$1" "${MSS_LAUNCHD_TIMEOUT:-60}" || return 1
    _mss_root rm -f "$2" || return 1
}

# _mss_install_plist <rendered-tmp> <dest>: root:wheel 0644, moved into place.
# On a real Mac a failed chown stops the step: a user-owned plist must never
# land in /Library/LaunchDaemons. Only inside a test sysroot (refused as root)
# is ownership best-effort, because a non-root phase A pass cannot hand a file
# to root and Linux has no wheel group.
_mss_install_plist() {
    if [ -n "${MSS_TEST_SYSROOT:-}" ]; then
        _mss_root chown root:wheel "$1" 2>/dev/null || _mss_root chown root "$1" 2>/dev/null || true
    else
        _mss_root chown root:wheel "$1" || { mss_error "cannot make $1 root:wheel; nothing was installed"; return 1; }
    fi
    _mss_root chmod 644 "$1" && _mss_root mv -f "$1" "$2"
}

# _mss_render_tmp <name>: where to render a plist before installing it. Never
# inside the daemon dir: install.sh runs as the user and /Library/LaunchDaemons
# is root:wheel 0755, so an unprivileged create there fails on every real
# install (#27 r2). mktemp -d is mode 0700, so the rendered job is readable only
# by this user until the privileged move makes it root:wheel 0644.
_mss_render_tmp() {
    _rt_dir=$(mktemp -d "${TMPDIR:-/tmp}/mss-plist.XXXXXX") \
        || { mss_error "cannot create a temporary directory for $1"; return 1; }
    printf '%s/%s\n' "$_rt_dir" "$1"
}

# _mss_install_plist_dir <rendered-tmp-dir>: remove the directory made by
# _mss_render_tmp once its file has been moved out.
_mss_install_plist_dir() { [ -d "$1" ] && rmdir "$1" 2>/dev/null; return 0; }

# _mss_gpu_last_exit_code: the boot job's last exit code as launchd reports it,
# or empty when the job is not loaded or says nothing. mss_gpu_verify puts it in
# the failure message, because "the limit is not set" and "the job ran and the
# kernel refused the value" need different fixes.
_mss_gpu_last_exit_code() {
    launchctl print "system/$1" 2>/dev/null \
        | sed -n 's/^[[:space:]]*last exit code = \(.*\)$/\1/p' | head -n 1
}

# mss_gpu_verify: poll the live limit until it equals MB (D4). On a timeout the
# message carries the job's last exit code.
mss_gpu_verify() {
    _want=$1; _i=0
    while [ "$(_mss_gpu_live_mb)" != "$_want" ]; do
        if [ "$_i" -ge $(( ${MSS_LAUNCHD_TIMEOUT:-60} * 2 )) ]; then
            _lec=$(_mss_gpu_last_exit_code "$MSS_GPU_LABEL")
            mss_error "$MSS_GPU_LABEL did not set iogpu.wired_limit_mb=$_want (live $(_mss_gpu_live_mb); last exit code = ${_lec:-unknown})"
            return 1
        fi
        sleep 0.5
        _i=$((_i + 1))
    done
    return 0
}

# mss_gpu_apply <percent>: the D4 apply table. Prints exactly one D8 line on
# stdout; the unset-row legacy note goes to stderr.
mss_gpu_apply() {
    _g=${1:-}
    case $_g in
        '')
            case $(_mss_gpu_plan "") in
                left-legacy)
                    _p=$(mss_gpu_job_read); _p=${_p#*|}
                    echo "$MSS_GPU_LABEL_LEGACY (${_p:-80}%) is left in place. It runs scripts/set-gpu-memory.sh, a file your user can edit, as root at every boot; set MSS_GPU_PERCENT=${_p:-80} to migrate it." >&2 ;;
            esac
            echo "GPU memory: left as is"
            return 0 ;;
        system)
            mss_gpu_jobs_remove || return 1
            echo "GPU memory: system default from the next boot"
            return 0 ;;
    esac
    _mb=$(mss_wired_limit_mb "$_g") || return 1
    _plan=$(_mss_gpu_plan "$_g") || return 1
    case $_plan in
        unchanged) echo "GPU memory: ${_g}% (${_mb} MB), unchanged"; return 0 ;;
        kickstart)
            _mss_root launchctl kickstart "system/$MSS_GPU_LABEL" || {
                mss_error "launchctl kickstart failed for $MSS_GPU_LABEL"; return 1; }
            mss_gpu_verify "$_mb" || return 1
            echo "GPU memory: ${_g}% (${_mb} MB), applied"
            return 0 ;;
    esac
    # bootstrap row: legacy first, then write, boot out a loaded new job, enable,
    # bootstrap, verify. A crash between the removals leaves no job, never two.
    _mss_gpu_remove_label "$MSS_GPU_LABEL_LEGACY" "$(mss_gpu_plist_legacy)" || return 1
    # Render in a private temp dir, then move it in through the privileged path.
    _tmp=$(_mss_render_tmp "$MSS_GPU_LABEL.plist") || return 1
    _tmp_dir=${_tmp%/*}
    if ! mss_gpu_render "$_g" "$_mb" > "$_tmp"; then
        rm -f "$_tmp"; _mss_install_plist_dir "$_tmp_dir"
        mss_error "cannot render $MSS_GPU_LABEL"; return 1
    fi
    if _mss_gpu_loaded "$MSS_GPU_LABEL"; then
        _mss_root launchctl bootout "system/$MSS_GPU_LABEL" || true
        mss_launchd_wait_gone "$MSS_GPU_LABEL" "${MSS_LAUNCHD_TIMEOUT:-60}" \
            || { rm -f "$_tmp"; _mss_install_plist_dir "$_tmp_dir"; return 1; }
    fi
    _mss_install_plist "$_tmp" "$(mss_gpu_plist_new)" \
        || { rm -f "$_tmp"; _mss_install_plist_dir "$_tmp_dir"; return 1; }
    _mss_install_plist_dir "$_tmp_dir"
    _mss_root launchctl enable "system/$MSS_GPU_LABEL" || {
        mss_error "launchctl enable failed for $MSS_GPU_LABEL"; return 1; }
    _mss_root launchctl bootstrap system "$(mss_gpu_plist_new)" || {
        mss_error "launchctl bootstrap failed for $MSS_GPU_LABEL"; return 1; }
    # Nothing here writes the sysctl: D4 verifies the boot job, so apply must
    # pass only if the job launchd just started set the value itself. A direct
    # write here would make verify pass on a job that never ran (#27 r2).
    mss_gpu_verify "$_mb" || return 1
    echo "GPU memory: ${_g}% (${_mb} MB), applied"
}

# ── D5 Docker: brew install of missing tools, and the autostart apply ──────────
# mss_docker_install_apply: step 6. Only MSS_DOCKER_INSTALL=yes installs, and
# only the tools missing from the boot job's PATH (validated earlier).
mss_docker_install_apply() {
    if [ "${MSS_DOCKER_INSTALL:-}" != yes ]; then
        echo "Docker install: not requested"
        return 0
    fi
    _tools=""
    for _t in colima docker; do
        [ -n "$(_mss_job_tool "$_t")" ] || _tools="$_tools$_t "
    done
    if [ -z "$_tools" ]; then
        echo "Docker install: already installed"
        return 0
    fi
    mss_acquire_docker_brew || return 1
    echo "Docker install: installed ${_tools% }"
}

# _mss_docker_render: the autostart plist as this run would install it. The
# template and the label do not change (constraint 9).
# The service user, as the boot job knows it. install.sh derives USER the same
# way, from OLLAMA_USER first: preferring $USER would render the job with the
# login user while install.sh applied it with the service user, so the picker
# summary and the apply step could disagree (#27 r2).
_mss_docker_user() { printf '%s\n' "${OLLAMA_USER:-${USER:-$(whoami)}}"; }
_mss_docker_render() { sed "s|<OLLAMA_USER>|$(_mss_docker_user)|g" "$REPO_DIR/config/com.colima.daemon.plist"; }

# mss_docker_job_script_check: com.colima.daemon runs the start-colima.sh its
# template names (/Users/<user>/mac-studio-server/scripts), whichever checkout
# installed it. A different file there, such as an older checkout, starts the
# VM by its own rules at every boot and can resize it, so MSS_DOCKER_AUTOSTART=yes
# needs that file to be this checkout's script. Runs before any change.
mss_docker_job_script_check() {
    [ "${MSS_DOCKER_AUTOSTART:-}" = yes ] || return 0
    _js=$(_mss_docker_render | sed -n 's|.*<string>\(/[^<]*/start-colima\.sh\)</string>.*|\1|p' | head -n 1)
    [ -n "$_js" ] || { mss_error "cannot find start-colima.sh in the $MSS_DOCKER_LABEL template"; return 1; }
    cmp -s "${MSS_TEST_SYSROOT:-}$_js" "$REPO_DIR/scripts/start-colima.sh" && return 0
    mss_error "MSS_DOCKER_AUTOSTART=yes: $MSS_DOCKER_LABEL runs $_js at every boot, and that is not this checkout's start-colima.sh; run install.sh from ${_js%/scripts/start-colima.sh}, or bring that checkout to this version"
    return 1
}

# _mss_docker_plan: the read-only autostart classification shared with the
# summary. Prints: unchanged starts removed off-unchanged left.
_mss_docker_plan() {
    _da=${MSS_DOCKER_AUTOSTART:-}
    case $_da in
        '') echo left; return ;;
        yes)
            _f=$(mss_daemon_dir)/$MSS_DOCKER_LABEL.plist
            if [ -f "$_f" ] && _mss_docker_render | cmp -s - "$_f" && _mss_gpu_loaded "$MSS_DOCKER_LABEL"; then
                echo unchanged
            else
                echo starts
            fi
            return ;;
        no)
            if [ -f "$(mss_daemon_dir)/$MSS_DOCKER_LABEL.plist" ]; then echo removed; else echo off-unchanged; fi
            return ;;
    esac
}

# mss_docker_autostart_apply: the D5 apply table. Prints one D8 line.
mss_docker_autostart_apply() {
    _da=${MSS_DOCKER_AUTOSTART:-}
    _f=$(mss_daemon_dir)/$MSS_DOCKER_LABEL.plist
    case $_da in
        '') echo "Docker at boot: left as is"; return 0 ;;
        yes)
            case $(_mss_docker_plan) in
                unchanged) echo "Docker at boot: on, unchanged"; return 0 ;;
            esac
            _tmp=$(_mss_render_tmp "$MSS_DOCKER_LABEL.plist") || return 1
            _tmp_dir=${_tmp%/*}
            if ! _mss_docker_render > "$_tmp"; then
                rm -f "$_tmp"; _mss_install_plist_dir "$_tmp_dir"
                mss_error "cannot render $MSS_DOCKER_LABEL"; return 1
            fi
            if _mss_gpu_loaded "$MSS_DOCKER_LABEL"; then
                _mss_root launchctl bootout "system/$MSS_DOCKER_LABEL" || true
                mss_launchd_wait_gone "$MSS_DOCKER_LABEL" "${MSS_LAUNCHD_TIMEOUT:-60}" \
                    || { rm -f "$_tmp"; _mss_install_plist_dir "$_tmp_dir"; return 1; }
            fi
            _mss_install_plist "$_tmp" "$_f" \
                || { rm -f "$_tmp"; _mss_install_plist_dir "$_tmp_dir"; return 1; }
            _mss_install_plist_dir "$_tmp_dir"
            _mss_root launchctl enable "system/$MSS_DOCKER_LABEL" || {
                mss_error "launchctl enable failed for $MSS_DOCKER_LABEL"; return 1; }
            _mss_root launchctl bootstrap system "$_f" || {
                mss_error "launchctl bootstrap failed for $MSS_DOCKER_LABEL"; return 1; }
            echo "Docker at boot: on, changed"
            return 0 ;;
        no)
            # The job goes; a running Colima is never stopped (constraint 1).
            [ -f "$_f" ] || { echo "Docker at boot: off, unchanged"; return 0; }
            _mss_root launchctl bootout "system/$MSS_DOCKER_LABEL" || true
            mss_launchd_wait_gone "$MSS_DOCKER_LABEL" "${MSS_LAUNCHD_TIMEOUT:-60}" || return 1
            _mss_root rm -f "$_f" || return 1
            echo "Docker at boot: off, changed"
            return 0 ;;
    esac
}

# ── D6 power restore ────────────────────────────────────────────────────────────
# mss_power_current: the pmset autorestart value, or rc 1 when this Mac has no
# such setting.
mss_power_current() {
    _mss_pmset -g 2>/dev/null | awk '$1=="autorestart"{print $2; found=1} END{exit !found}'
}

# mss_power_apply: one D8 line; a write only when set and different (D6).
mss_power_apply() {
    _v=${MSS_POWER_AUTORESTART:-}
    _rc=0
    _cur=$(mss_power_current) || _rc=1
    if [ -z "$_v" ]; then
        [ "$_rc" = 1 ] && { echo "Restart after power failure: left as is (unsupported)"; return 0; }
        case $_cur in
            1) echo "Restart after power failure: left as is (on)" ;;
            *) echo "Restart after power failure: left as is (off)" ;;
        esac
        return 0
    fi
    [ "$_rc" = 1 ] && { mss_error "this Mac has no restart-after-power-failure setting; unset MSS_POWER_AUTORESTART"; return 1; }
    case $_v in yes) _want=1; _word=on ;; *) _want=0; _word=off ;; esac
    if [ "$_cur" = "$_want" ]; then
        echo "Restart after power failure: $_word, unchanged"
        return 0
    fi
    # The lookup happens before sudo runs it, so a stub named by MSS_PMSET stays
    # a stub (D4c) — inside a test sysroot only.
    _mss_bin_hook MSS_PMSET /usr/bin/pmset
    _mss_root "$_mss_bin" -a autorestart "$_want" >/dev/null 2>&1 || {
        mss_error "pmset -a autorestart=$_want failed"; return 1; }
    _rb=$(mss_power_current) || { mss_error "pmset -g no longer prints autorestart"; return 1; }
    [ "$_rb" = "$_want" ] || { mss_error "pmset did not apply autorestart=$_want (reads $_rb)"; return 1; }
    echo "Restart after power failure: $_word, changed"
}

# ── picker summary variants (D3), shared classifiers, read-only ────────────────
mss_gpu_summary_line() {
    _g=${1:-}
    case $_g in
        '') echo "  gpu memory: left as is"; return ;;
        system) echo "  gpu memory: system default (from the next boot)"; return ;;
    esac
    case $(_mss_gpu_plan "$_g") in
        unchanged) echo "  gpu memory: ${_g}% of RAM (unchanged)" ;;
        *) echo "  gpu memory: ${_g}% of RAM (applied now and at every boot)" ;;
    esac
}

mss_power_summary_line() {
    _v=${MSS_POWER_AUTORESTART:-}
    _cur=$(mss_power_current) || return 0    # unsupported: the line is omitted
    if [ -z "$_v" ]; then
        case $_cur in 1) echo "  power restore: on (unchanged)" ;; *) echo "  power restore: off (unchanged)" ;; esac
        return
    fi
    case $_v in yes) _want=1; _word=on ;; *) _want=0; _word=off ;; esac
    if [ "$_cur" = "$_want" ]; then echo "  power restore: $_word (unchanged)"
    else echo "  power restore: $_word (changed)"; fi
}

mss_docker_install_summary_line() {
    if [ "${MSS_DOCKER_INSTALL:-}" != yes ]; then
        echo "  docker install: no"
        return
    fi
    _missing=""
    for _t in colima docker; do
        [ -n "$(_mss_job_tool "$_t")" ] || _missing="$_missing$_t "
    done
    case "$(printf '%s' "$_missing" | tr ' ' '\n' | grep -c . )" in
        0) echo "  docker install: already installed" ;;
        1) case $_missing in *colima*) echo "  docker install: Colima with Homebrew" ;;
                    *) echo "  docker install: the Docker CLI with Homebrew" ;; esac ;;
        *) echo "  docker install: Colima and the Docker CLI with Homebrew" ;;
    esac
}

mss_docker_autostart_summary_line() {
    case $(_mss_docker_plan) in
        left) echo "  docker at boot: left as is" ;;
        unchanged) echo "  docker at boot: on (unchanged)" ;;
        starts) echo "  docker at boot: on (starts now if stopped)" ;;
        removed) echo "  docker at boot: off (boot job removed; a running Colima keeps running)" ;;
        off-unchanged) echo "  docker at boot: off (unchanged)" ;;
    esac
}
