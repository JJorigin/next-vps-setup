#!/bin/bash
# next-vps-setup v1.1 -- local-file installation, root, Debian 13 amd64 VM.
# Run: bash /root/next-vps-setup.sh
# Inspect: bash /root/next-vps-setup.sh --status
# Retry after repairing a failure: bash /root/next-vps-setup.sh --resume
# No passwords, SSH configuration changes, TCP tuning or third-party repositories.
# Fresh systems only. Low-memory policy: MemTotal <= 1 GiB -> 1 GiB disk Swap, swappiness 10.

if [ -z "${BASH_VERSION:-}" ]; then printf '%s\n' 'Use bash /root/next-vps-setup.sh' >&2; exit 2; fi
if [[ ${BASH_SOURCE[0]:-} != "$0" ]]; then printf '%s\n' 'Do not source this file.' >&2; return 2; fi
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
export SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
unset APT_CONFIG UCF_FORCE_CONFFNEW UCF_FORCE_CONFFMISS
umask 077

BASE=/var/lib/next-vps-setup
STATE_FILE=$BASE/next-vps-setup-state.tsv
WORKER=$BASE/next-vps-setup.sh
RESULT=/var/lib/next-vps-setup-result.tsv
UNIT=next-vps-setup.service
UNIT_FILE=/etc/systemd/system/$UNIT
JAIL=/etc/fail2ban/jail.d/99-next-vps-setup.local
BALLOON_CONF=/etc/modprobe.d/next-vps-setup-balloon.conf
SWAP_DIR=/var/lib/nextvpssetup
SWAP_OWNER=$SWAP_DIR/owner.tsv
SWAP_FILE=$SWAP_DIR/swapfile
SWAP_UNIT=var-lib-nextvpssetup-swapfile.swap
SWAP_UNIT_FILE=/etc/systemd/system/$SWAP_UNIT
SWAP_SYSCTL=/etc/sysctl.d/99-next-vps-setup.conf
SWAP_BYTES=1073741824
SWAP_RESERVE_KIB=1048576
VERSION=1.1
declare -A S=()
IN_REBOOT=no

# BEGIN EMBEDDED user-interface
# Shared terminal messages; embedded into each downloadable script.
nv_ui_heading() {
    local title=$1
    printf '\n'
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then printf '\033[1;36m'; fi
    printf '%s\n' '============================================================' "  $title" '============================================================'
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then printf '\033[0m'; fi
}
nv_ui_stage_name() {
    case $1 in
        swap) printf '准备小内存交换空间' ;;
        update) printf '更新 Debian 官方软件包和内核' ;;
        configure) printf '配置主机名、时区和 SSH 防护' ;;
        kernel) printf '检查新内核启动状态' ;;
        balloon) printf '检查气球驱动禁用状态' ;;
        final|verify) printf '重启后核验配置和服务' ;;
        install) printf '下载并安装官方内核' ;;
        reboot) printf '等待重启并继续任务' ;;
        purge) printf '核验通过，清理旧内核' ;;
        cleanup) printf '清理本次任务文件' ;;
        done) printf '任务已完成' ;;
        *) printf '检查运行环境' ;;
    esac
}
nv_ui_progress() {
    nv_ui_heading "正在执行：$(nv_ui_stage_name "$1")"
    printf '%s\n' '请等待本阶段完成；不要重复启动或替换脚本。'
}
nv_ui_launch() {
    local title=$1 minutes=$2 receipt=$3 log=$4
    nv_ui_heading "$title · 后台任务已启动"
    printf '%s\n' \
        '  请留意：任务会自动重启，SSH 连接会断开。' \
        '  SSH 不会自动重连，需要使用原账号和端口手动连接。' \
        "  首次断线后，可先等待约 $minutes 分钟再连接。" \
        '  下载或启动较慢时会更久，请勿仅凭等待时间判断完成。' \
        '' \
        '  成功或失败后，下一次 root 交互式 SSH 登录会显示结果。' \
        '  此提示显示一次后自动清理；任务仍在执行时不会报成功。' \
        '' \
        '  如未看到登录提示，查看任务结果：' "    cat $receipt" \
        '  执行中的详细进度：' "    tail -f $log"
    printf '%s\n\n' '============================================================'
}
nv_ui_stopped() {
    nv_ui_heading '操作已停止 · 本次任务尚未完成'
    printf '%s\n' '请保留下面的原因和任务日志，处理后再使用同一文件恢复。'
    printf '原因：%s\n' "$*"
}
# END EMBEDDED user-interface

# BEGIN EMBEDDED ssh-notice
# BEGIN NEXT_VPS_SSH_NOTICE
# Embedded one-time root SSH login notice. This fragment only defines functions.
# API: nv_notice_install APP success|failure TASK_UUID STAGE NTP_STATUS ENTRY_PATH
# Tests may override the two root directories and helper functions before render.

nv_notice_is_root() { [[ ${EUID:-$(id -u)} == 0 ]]; }
nv_notice_owner() { printf '0\n'; }
nv_notice_uuid() { [[ $1 =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; }
nv_notice_id() { stat -c '%d:%i' -- "$1"; }
nv_notice_sha() { sha256sum -- "$1" | awk '{print $1}'; }
nv_notice_warn() { printf '\n[通知未完全清理] %s。请保留现状检查，不要递归删除系统目录。\n' "$*" >&2; }
nv_notice_plain() {
    local mode owner
    owner=$(nv_notice_owner) || return 1
    [[ -f $1 && ! -L $1 && $(stat -c %u -- "$1") == "$owner" && $(stat -c %h -- "$1") == 1 ]] || return 1
    mode=$(stat -c %a -- "$1") || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 022) == 0 ))
}
nv_notice_safe_dir() {
    local path=$1 mode owner
    owner=$(nv_notice_owner) || return 1
    while :; do
        [[ -d $path && ! -L $path && $(stat -c %u -- "$path") == "$owner" ]] || return 1
        mode=$(stat -c %a -- "$path") || return 1
        [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 022) == 0 )) || return 1
        [[ $path != / ]] || break
        path=${path%/*}; [[ -n $path ]] || path=/
    done
}
nv_notice_paths() {
    [[ $NV_NOTICE_APP == next-vps-setup || $NV_NOTICE_APP == next-vps-kernel-update ]] || return 1
    [[ $NV_NOTICE_PROFILE_DIR =~ ^/[a-zA-Z0-9_./-]+$ && $NV_NOTICE_DATA_ROOT =~ ^/[a-zA-Z0-9_./-]+$ ]] || return 1
    [[ $NV_NOTICE_PROFILE_DIR != *'/../'* && $NV_NOTICE_DATA_ROOT != *'/../'* && $NV_NOTICE_PROFILE_DIR != */.. && $NV_NOTICE_DATA_ROOT != */.. ]] || return 1
    NV_NOTICE_HOOK=$NV_NOTICE_PROFILE_DIR/$NV_NOTICE_APP-notice.sh
    NV_NOTICE_DIR=$NV_NOTICE_DATA_ROOT/$NV_NOTICE_APP-notice
    NV_NOTICE_PENDING=$NV_NOTICE_DIR/notice.txt
    NV_NOTICE_CLAIMED=$NV_NOTICE_DIR/consumed.txt
    NV_NOTICE_RECEIPT=$NV_NOTICE_DATA_ROOT/$NV_NOTICE_APP-result.tsv
}
nv_notice_terminal() {
    local values task phase status failed octets
    nv_notice_plain "$NV_NOTICE_RECEIPT" && (( $(stat -c %s -- "$NV_NOTICE_RECEIPT") <= 32768 )) || return 1
    octets=$(od -An -tx1 -- "$NV_NOTICE_RECEIPT") || return 1
    if grep -Eq '(^|[[:space:]])00([[:space:]]|$)' <<< "$octets"; then return 1; fi
    values=$(awk -F '\t' '
        NF!=2 {bad=1}
        $1=="task_id" {nt++;task=$2}
        $1=="phase" {np++;phase=$2}
        $1=="result_status" {ns++;status=$2}
        $1=="failed" {nf++;failed=$2}
        END{if(bad||nt!=1||np!=1||ns!=1||nf!=1)exit 1; printf "%s\t%s\t%s\t%s",task,phase,status,failed}' "$NV_NOTICE_RECEIPT") || return 1
    IFS=$'\t' read -r task phase status failed <<< "$values"
    [[ $task == "$NV_NOTICE_TASK" ]] || return 1
    case $NV_NOTICE_KIND in
        success) [[ $phase == done && $status == complete && $failed == no ]] ;;
        failure) [[ $failed == yes ]] ;;
        *) return 1 ;;
    esac
}
nv_notice_validate_dir() {
    local item
    nv_notice_safe_dir "$NV_NOTICE_DIR" && [[ $(stat -c %a -- "$NV_NOTICE_DIR") == 700 && $(nv_notice_id "$NV_NOTICE_DIR") == "$NV_NOTICE_DIR_ID" ]] || return 1
    for item in "$NV_NOTICE_DIR"/* "$NV_NOTICE_DIR"/.[!.]* "$NV_NOTICE_DIR"/..?*; do
        [[ -e $item || -L $item ]] || continue
        case $item in "$NV_NOTICE_PENDING"|"$NV_NOTICE_CLAIMED") ;; *) return 1 ;; esac
        nv_notice_plain "$item" && [[ $(stat -c %a -- "$item") == 600 && $(nv_notice_id "$item") == "$NV_NOTICE_TEXT_ID" && $(nv_notice_sha "$item") == "$NV_NOTICE_TEXT_SHA" ]] || return 1
    done
    [[ ! -e $NV_NOTICE_PENDING || ! -e $NV_NOTICE_CLAIMED ]]
}
nv_notice_cleanup_locked() {
    # Recheck each owned object; no glob or recursive deletion is used.
    nv_notice_plain "$NV_NOTICE_HOOK" && [[ $(nv_notice_id "$NV_NOTICE_HOOK") == "$NV_NOTICE_HOOK_ID" ]] || return 1
    if [[ -e $NV_NOTICE_DIR || -L $NV_NOTICE_DIR ]]; then
        nv_notice_validate_dir || return 1
        if [[ -e $NV_NOTICE_PENDING ]]; then rm -- "$NV_NOTICE_PENDING" || return 1; fi
        if [[ -e $NV_NOTICE_CLAIMED ]]; then rm -- "$NV_NOTICE_CLAIMED" || return 1; fi
        rmdir -- "$NV_NOTICE_DIR" || return 1
        sync -f "$NV_NOTICE_DATA_ROOT" || return 1
    fi
    nv_notice_plain "$NV_NOTICE_HOOK" && [[ $(nv_notice_id "$NV_NOTICE_HOOK") == "$NV_NOTICE_HOOK_ID" ]] || return 1
    rm -- "$NV_NOTICE_HOOK" || return 1
    sync -f "$NV_NOTICE_PROFILE_DIR" || return 1
}
nv_notice_consume() (
    # Runs as a subshell when the generated hook is sourced by /etc/profile.
    # Non-root, non-SSH, or non-interactive shells do not read/claim the payload.
    nv_notice_is_root || exit 0
    [[ -n ${SSH_CONNECTION:-} && $- == *i* ]] || exit 0
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
    nv_notice_paths || exit 0
    nv_notice_safe_dir "$NV_NOTICE_PROFILE_DIR" && nv_notice_safe_dir "$NV_NOTICE_DATA_ROOT" || { nv_notice_warn '通知父目录身份异常'; exit 0; }
    # Lock an existing stable directory inode: there is no lock file to leave.
    exec 8<"$NV_NOTICE_PROFILE_DIR" || { nv_notice_warn '无法打开通知目录'; exit 0; }
    flock -x 8 || { nv_notice_warn '无法取得通知锁'; exit 0; }
    [[ -e $NV_NOTICE_HOOK || -L $NV_NOTICE_HOOK ]] || exit 0
    # A previously sourced, now superseded hook must not consume a new notice.
    [[ $(nv_notice_id "$NV_NOTICE_HOOK") == "$NV_NOTICE_HOOK_ID" ]] || exit 0
    nv_notice_plain "$NV_NOTICE_HOOK" || { nv_notice_warn '通知入口身份异常'; exit 0; }
    # A success hook can be staged before cleanup deletes its worker. Until the
    # durable receipt is final, logging in must not consume or display it.
    nv_notice_terminal || exit 0
    if [[ -e $NV_NOTICE_DIR || -L $NV_NOTICE_DIR ]]; then
        nv_notice_validate_dir || { nv_notice_warn '通知内容或目录已变化，已拒绝显示和删除'; exit 0; }
        if [[ -e $NV_NOTICE_PENDING ]]; then
            # Rename claims delivery under the lock. Later logins only retry
            # cleanup if a previous display/cleanup was interrupted.
            mv -T -- "$NV_NOTICE_PENDING" "$NV_NOTICE_CLAIMED" || { nv_notice_warn '无法标记本次通知'; exit 0; }
            sync -f "$NV_NOTICE_DIR" || { nv_notice_warn '通知标记未能持久保存'; exit 0; }
            cat -- "$NV_NOTICE_CLAIMED" || { nv_notice_warn '通知输出未完成'; exit 0; }
        fi
    fi
    nv_notice_cleanup_locked || nv_notice_warn "通知文件尚未清理完成：$NV_NOTICE_HOOK"
    exit 0
)
nv_notice_render_hook() {
    printf '# next-vps-ssh-notice 1\n'
    printf '# app\t%s\n# task\t%s\n# generation\t%s\n# directory_id\t%s\n# text_id\t%s\n# text_sha\t%s\n# hook_id\t%s\n# kind\t%s\n' \
        "$NV_NOTICE_APP" "$NV_NOTICE_TASK" "$NV_NOTICE_GENERATION" "$NV_NOTICE_DIR_ID" "$NV_NOTICE_TEXT_ID" "$NV_NOTICE_TEXT_SHA" "$NV_NOTICE_HOOK_ID" "$NV_NOTICE_KIND"
    # /etc/profile.d is shared with POSIX login shells. This complete POSIX
    # command returns before a non-Bash shell reads any Bash-specific grammar.
    printf '[ -n "${BASH_VERSION:-}" ] || return 0\n'
    printf '(\n'
    printf 'NV_NOTICE_APP=%q\nNV_NOTICE_TASK=%q\nNV_NOTICE_GENERATION=%q\nNV_NOTICE_DIR_ID=%q\nNV_NOTICE_TEXT_ID=%q\nNV_NOTICE_TEXT_SHA=%q\nNV_NOTICE_HOOK_ID=%q\nNV_NOTICE_KIND=%q\nNV_NOTICE_PROFILE_DIR=%q\nNV_NOTICE_DATA_ROOT=%q\n' \
        "$NV_NOTICE_APP" "$NV_NOTICE_TASK" "$NV_NOTICE_GENERATION" "$NV_NOTICE_DIR_ID" "$NV_NOTICE_TEXT_ID" "$NV_NOTICE_TEXT_SHA" "$NV_NOTICE_HOOK_ID" "$NV_NOTICE_KIND" "$NV_NOTICE_PROFILE_DIR" "$NV_NOTICE_DATA_ROOT"
    declare -f nv_notice_is_root nv_notice_owner nv_notice_id nv_notice_sha nv_notice_warn nv_notice_plain nv_notice_safe_dir nv_notice_paths nv_notice_terminal nv_notice_validate_dir nv_notice_cleanup_locked nv_notice_consume
    printf 'nv_notice_consume\n)\n'
}
nv_notice_load_existing() {
    local first key value extra expected line n=0
    nv_notice_plain "$NV_NOTICE_HOOK" || return 1
    IFS= read -r first < "$NV_NOTICE_HOOK"
    [[ $first == '# next-vps-ssh-notice 1' ]] || return 1
    while IFS=$'\t' read -r key value extra; do
        n=$((n+1)); [[ $n != 1 ]] || continue
        ((n<=9)) || break
        [[ -z $extra && -n $value ]] || return 1
        case $n:$key in
            '2:# app') [[ $value == "$NV_NOTICE_APP" ]] || return 1 ;;
            '3:# task') nv_notice_uuid "$value" || return 1; NV_NOTICE_TASK=$value ;;
            '4:# generation') nv_notice_uuid "$value" || return 1; NV_NOTICE_GENERATION=$value ;;
            '5:# directory_id') [[ $value =~ ^[0-9]+:[0-9]+$ ]] || return 1; NV_NOTICE_DIR_ID=$value ;;
            '6:# text_id') [[ $value =~ ^[0-9]+:[0-9]+$ ]] || return 1; NV_NOTICE_TEXT_ID=$value ;;
            '7:# text_sha') [[ $value =~ ^[a-f0-9]{64}$ ]] || return 1; NV_NOTICE_TEXT_SHA=$value ;;
            '8:# hook_id') [[ $value =~ ^[0-9]+:[0-9]+$ ]] || return 1; NV_NOTICE_HOOK_ID=$value ;;
            '9:# kind') [[ $value == success || $value == failure ]] || return 1; NV_NOTICE_KIND=$value ;;
            *) return 1 ;;
        esac
    done < "$NV_NOTICE_HOOK"
    ((n>=9)) && [[ $(nv_notice_id "$NV_NOTICE_HOOK") == "$NV_NOTICE_HOOK_ID" ]] || return 1
    # Compare static source as data; do not source an earlier hook to inspect it.
    cmp -s "$NV_NOTICE_HOOK" <(nv_notice_render_hook) || return 1
    [[ ! -e $NV_NOTICE_DIR && ! -L $NV_NOTICE_DIR ]] || nv_notice_validate_dir
}
nv_notice_stage_name() {
    case $1 in
        swap) printf '准备交换空间' ;; update) printf '更新官方软件包' ;;
        configure) printf '配置系统基础设置' ;; kernel|install) printf '安装官方内核' ;;
        balloon) printf '核验气球驱动保护' ;; reboot) printf '重启并等待启动' ;;
        verify|final) printf '核验重启后的系统状态' ;; purge) printf '清理旧内核' ;;
        cleanup) printf '清理本次任务文件' ;; done) printf '完成核验' ;;
        *) printf '任务执行（%s）' "$1" ;;
    esac
}
nv_notice_text() {
    local kind=$1 stage=$2 ntp=$3 entry=$4 result log title
    result=/var/lib/$NV_NOTICE_APP-result.tsv
    if [[ $NV_NOTICE_APP == next-vps-setup ]]; then log=/var/lib/next-vps-setup/next-vps-setup.log; title='VPS 初始化'
    else log=/var/lib/next-vps-kernel-update/run.log; title='内核维护'; fi
    printf '\n╭──────────────────────────────────────────────╮\n'
    if [[ $kind == success ]]; then
        printf '  ✓ %s已完成\n' "$title"
        printf '  状态：成功；必需步骤和最终核查已通过，可继续使用服务器。\n'
    else
        printf '  ✗ %s已停止\n' "$title"
        printf '  状态：失败，任务未完成，请先查看原因。\n  出错阶段：%s\n' "$(nv_notice_stage_name "$stage")"
    fi
    if [[ $ntp == unsynchronized || $ntp == unavailable ]]; then
        printf '  ⚠ 时间同步警告：尚未确认同步，沿用系统当前时间。\n'
    fi
    if [[ $kind == success ]]; then
        printf '  如需查看详细记录：\n    cat %s\n' "$result"
    else
        printf '  下一步：查看失败详情。\n    journalctl -u %s.service -n 80 --no-pager\n' "$NV_NOTICE_APP"
        printf '  文件日志：%s\n' "$log"
        printf '  修复原因后，使用同版本文件恢复：\n    bash %s --resume\n' "$entry"
        printf '  如入口已被清理，先上传同版本脚本到上述原路径。\n'
    fi
    printf '  此为一次性通知；读取后自动清理通知文件。\n╰──────────────────────────────────────────────╯\n\n'
}
nv_notice_install() (
    set -Eeuo pipefail
    export LC_ALL=C
    umask 077
    local kind=${2:-} task=${3:-} stage=${4:-} ntp=${5:-} entry=${6:-}
    local temp_dir= temp_hook= published_dir=no published_hook=no code
    (( $#==6 )) || { printf 'NOTICE_ERROR: invalid argument count\n' >&2; exit 1; }
    NV_NOTICE_APP=$1
    NV_NOTICE_PROFILE_DIR=${NV_NOTICE_PROFILE_DIR:-/etc/profile.d}
    NV_NOTICE_DATA_ROOT=${NV_NOTICE_DATA_ROOT:-/var/lib}
    nv_notice_is_root && nv_notice_paths || { printf 'NOTICE_ERROR: root and recognized application required\n' >&2; exit 1; }
    [[ $kind == success || $kind == failure ]] && nv_notice_uuid "$task" || { printf 'NOTICE_ERROR: only terminal states are accepted\n' >&2; exit 1; }
    [[ $stage =~ ^[a-z][a-z0-9_-]{0,31}$ && ( $ntp == synchronized || $ntp == unsynchronized || $ntp == unavailable || $ntp == not-recorded ) ]] || { printf 'NOTICE_ERROR: invalid status fields\n' >&2; exit 1; }
    [[ $entry == /root/*.sh && $entry =~ ^/root/[a-zA-Z0-9_./-]+\.sh$ && $entry != *'/../'* && $entry != *'/./'* ]] || { printf 'NOTICE_ERROR: invalid entry path\n' >&2; exit 1; }
    nv_notice_safe_dir "$NV_NOTICE_PROFILE_DIR" && nv_notice_safe_dir "$NV_NOTICE_DATA_ROOT" || { printf 'NOTICE_ERROR: unsafe parent directory\n' >&2; exit 1; }
    exec 8<"$NV_NOTICE_PROFILE_DIR" || exit 1
    flock -x 8 || exit 1
    if [[ -e $NV_NOTICE_HOOK || -L $NV_NOTICE_HOOK ]]; then
        nv_notice_load_existing && nv_notice_cleanup_locked || { printf 'NOTICE_ERROR: existing notice identity differs; not overwritten\n' >&2; exit 1; }
    fi
    [[ ! -e $NV_NOTICE_DIR && ! -L $NV_NOTICE_DIR ]] || { printf 'NOTICE_ERROR: unknown notice directory; not adopted\n' >&2; exit 1; }
    # Delete only known temporary objects on ordinary install errors. A power
    # interruption can require inspection; no unrelated path is ever adopted.
    trap 'code=$?; if [[ -n $temp_hook && -f $temp_hook && ! -L $temp_hook ]]; then rm -- "$temp_hook" || true; fi; if [[ -n $temp_dir && -d $temp_dir && ! -L $temp_dir ]]; then [[ ! -f $temp_dir/notice.txt ]] || rm -- "$temp_dir/notice.txt" || true; rmdir -- "$temp_dir" || true; fi; if [[ $published_dir == yes && $published_hook == no ]] && nv_notice_validate_dir; then [[ ! -f $NV_NOTICE_PENDING ]] || rm -- "$NV_NOTICE_PENDING" || true; rmdir -- "$NV_NOTICE_DIR" || true; fi; exit "$code"' EXIT
    # Explicit checks are intentional: the failure trap may invoke this function
    # in an `if`/`||` context, where Bash suppresses errexit inside functions.
    temp_dir=$(mktemp -d "$NV_NOTICE_DATA_ROOT/.$NV_NOTICE_APP-notice.XXXXXX") || exit 1
    [[ $temp_dir == "$NV_NOTICE_DATA_ROOT/.$NV_NOTICE_APP-notice."* && -d $temp_dir && ! -L $temp_dir ]] || exit 1
    temp_hook=$(mktemp "$NV_NOTICE_PROFILE_DIR/.$NV_NOTICE_APP-notice.XXXXXX") || exit 1
    [[ $temp_hook == "$NV_NOTICE_PROFILE_DIR/.$NV_NOTICE_APP-notice."* && -f $temp_hook && ! -L $temp_hook ]] || exit 1
    NV_NOTICE_TASK=$task; NV_NOTICE_KIND=$kind
    NV_NOTICE_GENERATION=$(cat /proc/sys/kernel/random/uuid) || exit 1
    nv_notice_uuid "$NV_NOTICE_GENERATION" || exit 1
    NV_NOTICE_DIR_ID=$(nv_notice_id "$temp_dir") || exit 1
    nv_notice_text "$kind" "$stage" "$ntp" "$entry" > "$temp_dir/notice.txt" || exit 1
    chmod 0600 "$temp_dir/notice.txt" || exit 1
    NV_NOTICE_TEXT_ID=$(nv_notice_id "$temp_dir/notice.txt") || exit 1
    NV_NOTICE_TEXT_SHA=$(nv_notice_sha "$temp_dir/notice.txt") || exit 1
    NV_NOTICE_HOOK_ID=$(nv_notice_id "$temp_hook") || exit 1
    nv_notice_render_hook > "$temp_hook" || exit 1
    chmod 0644 "$temp_hook" || exit 1
    sync -f "$temp_dir/notice.txt" && sync -f "$temp_hook" || exit 1
    mv -T -- "$temp_dir" "$NV_NOTICE_DIR" || exit 1
    temp_dir=; published_dir=yes
    sync -f "$NV_NOTICE_DATA_ROOT" || exit 1
    mv -T -- "$temp_hook" "$NV_NOTICE_HOOK" || exit 1
    temp_hook=; published_hook=yes
    sync -f "$NV_NOTICE_PROFILE_DIR" || exit 1
    trap - EXIT
)
# END NEXT_VPS_SSH_NOTICE
# END EMBEDDED ssh-notice

die() { nv_ui_stopped "$*" >&2; exit 1; }
note() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
publish_login_notice() {
    local kind=$1 ntp=${S[ntp_status]:-not-recorded}
    case $ntp in synchronized|unsynchronized|unavailable) ;; *) ntp=not-recorded ;; esac
    nv_notice_install next-vps-setup "$kind" "${S[task_id]}" "${S[phase]}" "$ntp" "${S[entry_path]}"
}
validate_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
validate_boot_id() { [[ $1 =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; }
validate_hostname() {
    local value=$1 label
    [[ ${#value} -ge 1 && ${#value} -le 64 && $value != .* && $value != *. ]] || return 1
    [[ $value =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
    [[ $value != *..* ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$value"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}
boot_transition() {
    local before=$1 now=$2 count=$3 target=$4 running=$5
    validate_boot_id "$before" && validate_boot_id "$now" || return 1
    [[ $count =~ ^[1-3]$ ]] || return 1
    if [[ $before == "$now" ]]; then printf 'WAIT\n'; return 0; fi
    [[ $target != - && $target == "$running" ]] || return 1
    printf 'READY\n'
}
memtotal() {
    awk '$1=="MemTotal:" {n++; if (NF!=3 || $2!~/^[1-9][0-9]*$/ || $3!="kB") bad=1; v=$2}
         END {if(n!=1 || bad)exit 1; print v}' /proc/meminfo
}
memory_policy() {
    local value=$1
    [[ $value =~ ^[1-9][0-9]{0,14}$ ]] || return 1
    if (( value <= 1048576 )); then printf 'disk1g\n'; else printf 'skip\n'; fi
}
boot_id() { local value; value=$(cat /proc/sys/kernel/random/boot_id); validate_boot_id "$value" || return 1; printf '%s\n' "$value"; }
file_sha() { sha256sum -- "$1" | awk '{print $1}'; }
file_identity() { stat -c '%d:%i' -- "$1"; }
plain_root_file() {
    local path=$1 mode
    [[ -f $path && ! -L $path && $(stat -c %u -- "$path") == 0 ]] || return 1
    mode=$(stat -c %a -- "$path") || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 022) == 0 ))
}
safe_entry_path() {
    local path=$1 parent
    [[ $path == /root/*.sh && $path =~ ^/root/[a-zA-Z0-9_./-]+\.sh$ ]] || return 1
    plain_root_file "$path" || return 1
    [[ $(readlink -e -- "$path") == "$path" ]] || return 1
    parent=${path%/*}
    while :; do
        [[ -d $parent && ! -L $parent && $(stat -c %u -- "$parent") == 0 ]] || return 1
        local mode; mode=$(stat -c %a -- "$parent") || return 1
        (( (8#$mode & 022) == 0 )) || return 1
        [[ $parent == / ]] && break
        parent=${parent%/*}; [[ -n $parent ]] || parent=/
    done
}
validate_state_value() {
    local key=$1 value=$2
    [[ -n $value && $value != *[[:cntrl:]]* ]] || return 1
    case $key in
        format) [[ $value == 3 ]] ;;
        task_id) validate_boot_id "$value" ;;
        machine_id) [[ $value =~ ^[a-f0-9]{32}$ ]] ;;
        hostname) validate_hostname "$value" ;;
        ssh_port) validate_port "$value" ;;
        kernel_meta) [[ $value == linux-image-amd64 || $value == linux-image-cloud-amd64 ]] ;;
        target_kernel) [[ $value == - || $value =~ ^6\.12\.[0-9]+[a-zA-Z0-9.+~-]*-amd64$ ]] ;;
        ntp_unit) [[ $value == - || $value == systemd-timesyncd.service || $value == chrony.service || $value == ntpsec.service || $value == ntp.service || $value == openntpd.service ]] ;;
        ntp_status) [[ $value == pending || $value == synchronized || $value == unsynchronized || $value == unavailable ]] ;;
        balloon) [[ $value == pending || $value == module || $value == absent ]] ;;
        swap_policy) [[ $value == skip || $value == disk1g ]] ;;
        mem_kib) [[ $value =~ ^[1-9][0-9]{0,14}$ ]] ;;
        swap_uuid) [[ $value == - ]] || validate_boot_id "$value" ;;
        swap_identity) [[ $value == - || $value =~ ^[0-9]+:[0-9]+$ ]] ;;
        swap_status) [[ $value == pending || $value == building || $value == active || $value == verified || $value == skipped ]] ;;
        phase) [[ $value == update || $value == configure || $value == kernel || $value == balloon || $value == swap || $value == final || $value == cleanup || $value == "done" ]] ;;
        boot_before|verified_boot) [[ $value == - ]] || validate_boot_id "$value" ;;
        last_config_boot) validate_boot_id "$value" ;;
        reboot_count) [[ $value =~ ^[0-3]$ ]] ;;
        reboot_wait) [[ $value == none || $value == kernel || $value == balloon || $value == final ]] ;;
        failed) [[ $value == yes || $value == no ]] ;;
        entry_path) [[ $value == /root/* ]] ;;
        entry_identity) [[ $value =~ ^[0-9]+:[0-9]+$ ]] ;;
        entry_sha|worker_sha|ssh_policy_sha) [[ $value =~ ^[a-f0-9]{64}$ ]] ;;
        result_status) [[ $value == running || $value == cleanup_pending || $value == complete ]] ;;
        verified_at) [[ $value =~ ^[0-9]{1,12}$ ]] ;;
        config_hashes) [[ $value == - || $value =~ ^[a-f0-9]{64}$ ]] ;;
        packages) [[ $value == - || $value =~ ^[a-zA-Z0-9.+:~=@,/_-]+$ ]] ;;
        *) return 1 ;;
    esac
}
state_keys() {
    printf '%s\n' format task_id machine_id hostname ssh_port kernel_meta target_kernel ntp_unit balloon swap_policy swap_status swap_uuid swap_identity mem_kib phase boot_before last_config_boot reboot_count reboot_wait failed entry_path entry_identity entry_sha worker_sha ssh_policy_sha result_status verified_boot verified_at config_hashes packages
    printf '%s\n' ntp_status
}
validate_state() {
    local key
    while IFS= read -r key; do
        [[ -v S[$key] ]] && validate_state_value "$key" "${S[$key]}" || return 1
    done < <(state_keys)
    [[ ${S[format]} == 3 && ${#S[@]} == 31 ]] || return 1
    [[ ${S[ntp_status]} != synchronized || ${S[ntp_unit]} != - ]] || return 1
    [[ ${S[result_status]} == running || ${S[ntp_status]} != pending ]] || return 1
    [[ $(memory_policy "${S[mem_kib]}") == "${S[swap_policy]}" ]] || return 1
    if [[ ${S[swap_policy]} == skip ]]; then
        [[ ${S[swap_uuid]} == - && ${S[swap_identity]} == - && ( ${S[swap_status]} == pending || ${S[swap_status]} == skipped ) ]] || return 1
    else
        [[ ${S[swap_status]} != skipped ]] || return 1
        if [[ ${S[swap_status]} != pending ]]; then validate_boot_id "${S[swap_uuid]}" || return 1; fi
        if [[ ${S[swap_status]} == active || ${S[swap_status]} == verified ]]; then
            [[ ${S[swap_identity]} =~ ^[0-9]+:[0-9]+$ ]] || return 1
        fi
    fi
    if [[ ${S[reboot_wait]} != none ]]; then
        validate_boot_id "${S[boot_before]}" && [[ ${S[reboot_count]} != 0 && ${S[target_kernel]} != - ]] || return 1
    fi
    [[ ${S[phase]} == swap || ${S[phase]} == update || ${S[target_kernel]} != - ]] || return 1
    [[ ${S[reboot_wait]} == none || ${S[reboot_wait]} == "${S[phase]}" ]] || return 1
    case ${S[result_status]} in
        complete) [[ ${S[phase]} == "done" && ${S[failed]} == no ]] || return 1 ;;
        cleanup_pending) [[ ${S[phase]} == cleanup ]] || return 1 ;;
        running) [[ ${S[phase]} != cleanup && ${S[phase]} != "done" ]] || return 1 ;;
    esac
    if [[ ${S[result_status]} != running ]]; then
        if [[ ${S[swap_policy]} == disk1g ]]; then [[ ${S[swap_status]} == verified ]] || return 1
        else [[ ${S[swap_status]} == skipped ]] || return 1; fi
        validate_boot_id "${S[verified_boot]}" && [[ ${S[verified_at]} != 0 && ${S[config_hashes]} != - && ${S[packages]} != - ]] || return 1
        [[ ${S[reboot_count]} != 0 && ${S[reboot_wait]} == none && ${S[last_config_boot]} != "${S[verified_boot]}" ]] || return 1
    fi
}
parse_state() {
    local file=$1 line key value size octets
    S=()
    [[ -f $file && ! -L $file ]] || return 1
    size=$(stat -c %s -- "$file") || return 1
    [[ $size =~ ^[0-9]+$ ]] && ((size<=16384)) || return 1
    # NUL bytes cannot be represented by Bash variables; reject before read.
    octets=$(od -An -tx1 -- "$file") || return 1
    if grep -Eq '(^|[[:space:]])00([[:space:]]|$)' <<< "$octets"; then return 1; fi
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *$'\t'* ]] || return 1
        key=${line%%$'\t'*}; value=${line#*$'\t'}
        [[ $key =~ ^[a-z_]+$ && $value != *$'\t'* && ! -v S[$key] ]] || return 1
        validate_state_value "$key" "$value" || return 1
        S[$key]=$value
    done < "$file"
    validate_state
}
discard_state_temp() {
    local path=$1
    if [[ -f $path && ! -L $path ]]; then
        if ! rm -- "$path"; then printf 'State temporary file retained: %s\n' "$path" >&2; fi
    else printf 'State temporary path changed, not removed: %s\n' "$path" >&2; fi
    return 0
}
serialize_state() {
    local key
    while IFS= read -r key; do printf '%s\t%s\n' "$key" "${S[$key]}" || return 1; done < <(state_keys)
}
write_state_to() {
    local file=$1 tmp key parent=${1%/*}
    validate_state || die 'Internal state validation failed.'
    [[ -d $parent && ! -L $parent ]] || die "Invalid state parent: $parent"
    [[ ! -L $file ]] || die 'State destination is a symlink.'
    tmp=$(mktemp "$parent/.next-vps-setup-state.XXXXXX") || return 1
    if ! serialize_state > "$tmp"; then discard_state_temp "$tmp"; return 1; fi
    if ! (parse_state "$tmp"); then discard_state_temp "$tmp"; return 1; fi
    if ! chmod 0600 "$tmp"; then discard_state_temp "$tmp"; return 1; fi
    if ! sync -f "$tmp"; then discard_state_temp "$tmp"; return 1; fi
    if ! mv -T -- "$tmp" "$file"; then discard_state_temp "$tmp"; return 1; fi
    sync -f "$parent" || return 1
}
save_state() { write_state_to "$STATE_FILE"; }
dirty() { S[last_config_boot]=$(boot_id); save_state; }
installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true) == 'install ok installed' ]]; }
ssh_policy_sha() {
    /usr/sbin/sshd -T | awk '$1=="port" || $1=="passwordauthentication" || $1=="permitrootlogin" || $1=="pubkeyauthentication" || $1=="kbdinteractiveauthentication" || $1=="usepam"' | sort | sha256sum | awk '{print $1}'
}
check_ssh() {
    local expected=$1 configured listeners
    /usr/sbin/sshd -t || die 'Invalid SSH configuration.'
    systemctl is-active --quiet ssh.service || die 'ssh.service is not active.'
    if systemctl is-active --quiet ssh.socket; then die 'SSH socket activation is unsupported by this version; no SSH configuration was changed.'; fi
    configured=$(/usr/sbin/sshd -T | awk '$1=="port" {print $2}' | sort -u)
    [[ $configured == "$expected" ]] || die 'Expected port and SSH configuration disagree, or multiple ports are configured.'
    listeners=$(ss -H -lntp | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}' | sort -u)
    [[ $listeners == "$expected" ]] || die 'Actual sshd listeners disagree with the selected port.'
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        local _client _client_port _server server_port rest
        read -r _client _client_port _server server_port rest <<< "$SSH_CONNECTION"
        [[ -z ${rest:-} && $server_port == "$expected" ]] || die 'Current SSH connection uses a different server port.'
    fi
    [[ ! -v S[ssh_policy_sha] || $(ssh_policy_sha) == "${S[ssh_policy_sha]}" ]] || die 'SSH authentication policy changed; inspect before continuing.'
}
detect_ntp() {
    local pkg unit found=- count=0
    for pkg in systemd-timesyncd chrony ntpsec openntpd; do
        if installed "$pkg"; then
            case $pkg in systemd-timesyncd) unit=systemd-timesyncd.service ;; chrony) unit=chrony.service ;; ntpsec) unit=ntpsec.service ;; openntpd) unit=openntpd.service ;; esac
            found=$unit; count=$((count+1))
        fi
    done
    (( count <= 1 )) || die 'Multiple time providers are installed; not replacing them.'
    printf '%s\n' "$found"
}
check_resources() {
    local root_free boot_free inodes available needed_root=2097152
    root_free=$(df -Pk / | awk 'END{print $4}')
    boot_free=$(df -Pk /boot | awk 'END{print $4}')
    inodes=$(df -Pi / | awk 'END{print $4}')
    available=$(awk '$1=="MemAvailable:"{print $2}' /proc/meminfo)
    [[ $root_free =~ ^[0-9]+$ && $boot_free =~ ^[0-9]+$ && $inodes =~ ^[0-9]+$ && $available =~ ^[0-9]+$ ]] || die 'Cannot inspect available resources.'
    if [[ ${S[swap_status]:-pending} == active || ${S[swap_status]:-pending} == verified ]]; then needed_root=1048576; fi
    (( root_free >= needed_root && boot_free >= 204800 && inodes >= 10000 && available >= 131072 )) || die 'Insufficient resources: need 2 GiB initial root space (1 GiB after the owned Swap exists), 200 MiB /boot, 10000 free inodes and 128 MiB MemAvailable.' 
}
check_os() {
    [[ $(id -u) == 0 ]] || die 'Use a root login, or sudo -i, then run the local /root copy.'
    local command
    for command in apt-get apt-cache awk blkid cat chmod chown cmp cp cut date dd df dpkg dpkg-query env find findmnt flock getconf getent grep hostnamectl id install ln mkdir mktemp mkswap modprobe mv od readlink rm rmdir sed sha256sum sleep sort ss stat swapon sync sysctl systemctl systemd-detect-virt timedatectl uname update-initramfs; do
        command -v "$command" >/dev/null || die "Missing prerequisite: $command"
    done
    [[ -f /etc/debian_version && -d /run/systemd/system ]] || die 'Debian with systemd is required.'
    grep -Eq '^ID=(debian|"debian")$' /etc/os-release && grep -Eq '^VERSION_ID=(13|"13")$' /etc/os-release || die 'Only Debian 13 is supported.'
    [[ $(dpkg --print-architecture) == amd64 ]] || die 'Only amd64 is supported.'
    if systemd-detect-virt --container --quiet; then die 'Containers are unsupported.'; fi
    local virtualization
    virtualization=$(systemd-detect-virt --vm) || die 'A detectable virtual machine is required.'
    [[ $virtualization != none ]] || die 'A virtual machine is required.'
    [[ $(date +%s) -ge 1754697600 ]] || die 'System clock precedes Debian 13 release; repair time first.'
    local audit
    audit=$(dpkg --audit)
    [[ -z $audit ]] || die 'dpkg has incomplete packages; repair them before retrying.'
    local selections
    selections=$(dpkg --get-selections)
    if awk '$2=="hold"{found=1} END{exit !found}' <<< "$selections"; then die '发现锁定的软件包。请先确认锁定原因，本次没有解除限制。'; fi

}
# BEGIN NEXT-VPS OFFICIAL APT VIEW
# This block is embedded unchanged in both standalone delivery scripts.
official_apt_root() { printf '%s-apt\n' "$BASE"; }
official_apt_file_ok() {
    local mode
    [[ -f $1 && ! -L $1 && $(stat -c %u -- "$1") == 0 && $(stat -c %h -- "$1") == 1 ]] || return 1
    mode=$(stat -c %a -- "$1") || return 1
    (( (8#$mode & 022) == 0 ))
}
official_apt_dir_ok() {
    local mode uid apt_uid
    [[ -d $1 && ! -L $1 ]] || return 1
    mode=$(stat -c %a -- "$1"); uid=$(stat -c %u -- "$1") || return 1
    apt_uid=$(id -u _apt) || return 1
    [[ $uid == 0 || ( ${2:-root} == download && $uid == "$apt_uid" ) ]] || return 1
    if [[ ${2:-root} == download ]]; then [[ $mode == 755 || $mode == 700 ]]; else [[ $mode == 755 ]]; fi
}
check_sources() {
    # Host source files, pins and APT hooks are neither loaded nor changed.
    official_apt_file_ok /usr/share/keyrings/debian-archive-keyring.gpg &&
        [[ -r /usr/share/keyrings/debian-archive-keyring.gpg ]] || die '缺少可读取的 Debian 官方签名密钥文件，请先检查系统完整性。'
    (( (8#$(stat -c %a -- /usr/share/keyrings/debian-archive-keyring.gpg) & 004) != 0 )) || die 'APT 下载沙箱无法读取 Debian 签名密钥，请检查文件权限。'
    id -u _apt >/dev/null 2>&1 || die '系统缺少 APT 下载沙箱用户，请先修复基础软件包。'
    [[ $BASE =~ ^/[a-zA-Z0-9_./-]+$ ]] || die 'Unsafe private APT path.'
}
official_apt_sources_content() {
    cat <<'OFFICIAL_SOURCES'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
OFFICIAL_SOURCES
}
official_apt_config_content() {
    local root; root=$(official_apt_root)
    cat <<OFFICIAL_CONFIG
Dir "/";
Dir::Etc "$root";
Dir::Etc::main "$root/empty.conf";
Dir::Etc::parts "$root/parts";
Dir::Etc::sourcelist "$root/official.sources";
Dir::Etc::sourceparts "$root/sourceparts";
Dir::Etc::preferences "$root/preferences";
Dir::Etc::preferencesparts "$root/preferencesparts";
Dir::Etc::trusted "/usr/share/keyrings/debian-archive-keyring.gpg";
Dir::Etc::trustedparts "$root/trustedparts";
Dir::Etc::netrc "$root/auth.conf";
Dir::Etc::netrcparts "$root/authparts";
Dir::State "/var/lib/apt";
Dir::State::status "/var/lib/dpkg/status";
Dir::State::extended_states "/var/lib/apt/extended_states";
Dir::State::lists "$root/lists";
Dir::Cache "/var/cache/apt";
Dir::Cache::archives "/var/cache/apt/archives";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
Dir::Log "/var/log/apt";
Dir::Bin::dpkg "/usr/bin/dpkg";
APT::Architecture "amd64";
APT::Architectures { "amd64"; };
APT::Sandbox::User "_apt";
APT::Get::AutomaticRemove "false";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::Protect-Kernels "true";
APT::NeverAutoRemove::KernelCount "2";
APT::Get::AllowUnauthenticated "false";
APT::Get::allow-downgrades "false";
APT::Get::allow-change-held-packages "false";
Acquire::AllowInsecureRepositories "false";
Acquire::AllowDowngradeToInsecureRepositories "false";
Acquire::Check-Valid-Until "true";
Acquire::Languages "none";
Acquire::PDiffs "false";
Acquire::Retries "2";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
DPkg::Lock::Timeout "300";
DPkg::Options { "--force-confold"; };
OFFICIAL_CONFIG
}
official_apt_publish() {
    local path=$1 content=$2 tmp
    if [[ -e $path || -L $path ]]; then
        official_apt_file_ok "$path" && cmp -s "$path" <(printf '%s' "$content") || die '本次更新使用的官方源配置已被改动，已停止以避免使用未知配置。'
        return
    fi
    tmp=$(mktemp "${path%/*}/.official-apt.XXXXXX") || return 1
    if ! printf '%s' "$content" > "$tmp" || ! chmod 0644 "$tmp" || ! sync -f "$tmp"; then
        rm -- "$tmp" || true; return 1
    fi
    if ! mv -T -- "$tmp" "$path"; then rm -- "$tmp" || true; return 1; fi
    sync -f "${path%/*}"
}
official_apt_check_tree() {
    local root path relative uid apt_uid listing
    root=$(official_apt_root)
    official_apt_dir_ok "$root" || return 1
    apt_uid=$(id -u _apt) || return 1
    listing=$(find -P "$root" -xdev -mindepth 1 -print) || return 1
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        relative=${path#"$root"/}
        case $relative in
            owner|apt.conf|empty.conf|official.sources|preferences|auth.conf)
                official_apt_file_ok "$path" || return 1 ;;
            parts|sourceparts|preferencesparts|trustedparts|authparts|lists)
                official_apt_dir_ok "$path" || return 1 ;;
            lists/partial|lists/auxfiles)
                official_apt_dir_ok "$path" download || return 1 ;;
            lists/*)
                [[ $relative =~ ^lists/(partial/|auxfiles/)?(lock|deb\.debian\.org_debian_dists_trixie[-a-zA-Z0-9_.%+~]*|security\.debian\.org_debian-security_dists_trixie-security[-a-zA-Z0-9_.%+~]*)$ ]] || return 1
                [[ -f $path && ! -L $path && $(stat -c %h -- "$path") == 1 ]] || return 1
                uid=$(stat -c %u -- "$path") || return 1
                [[ $uid == 0 || $uid == "$apt_uid" ]] || return 1 ;;
            *) return 1 ;;
        esac
    done <<< "$listing"
}
official_apt_prepare() {
    local root directory content
    check_sources
    root=$(official_apt_root)
    official_apt_dir_ok "${root%/*}" || die 'Unsafe private APT parent directory.'
    [[ -n ${S[task_id]:-} && ${S[task_id]} =~ ^[a-f0-9-]{36}$ ]] || die 'A task identity is required for private APT.'
    if [[ ! -e $root && ! -L $root ]]; then mkdir -m 0755 -- "$root"; fi
    official_apt_dir_ok "$root" || die '更新暂存目录的权限或类型不安全，已停止。'
    if [[ ! -e $root/owner && ! -L $root/owner ]]; then
        [[ -z $(find -P "$root" -mindepth 1 -maxdepth 1 -print -quit) ]] || die 'Unowned private APT data exists.'
    fi
    official_apt_publish "$root/owner" "${S[task_id]}"$'\n'
    for directory in parts sourceparts preferencesparts trustedparts authparts lists lists/partial; do
        if [[ ! -e $root/$directory && ! -L $root/$directory ]]; then mkdir -m 0755 -- "$root/$directory"; fi
        case $directory in lists/partial) official_apt_dir_ok "$root/$directory" download ;; *) official_apt_dir_ok "$root/$directory" ;; esac || die 'Unsafe private APT subdirectory.'
    done
    official_apt_publish "$root/empty.conf" ''
    official_apt_publish "$root/preferences" ''
    official_apt_publish "$root/auth.conf" ''
    content=$(official_apt_sources_content); official_apt_publish "$root/official.sources" "$content"$'\n'
    content=$(official_apt_config_content); official_apt_publish "$root/apt.conf" "$content"$'\n'
    official_apt_check_tree || die '更新暂存目录出现未知内容或权限变化，已停止，请保留现场检查。'
}
official_apt_exec() {
    local tool=$1 root; shift
    root=$(official_apt_root)
    env -u APT_CONFIG -u DPKG_ROOT -u DPKG_ADMINDIR -u DPKG_FORCE -u DPKG_FRONTEND_LOCKED \
        -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        APT_CONFIG="$root/apt.conf" DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 NEEDRESTART_MODE=l \
        "$tool" "$@"
}
apt_run() { official_apt_prepare; official_apt_exec apt-get "$@"; }
apt_cache() { official_apt_prepare; official_apt_exec apt-cache "$@"; }
official_apt_ready() {
    local root prefix file found
    root=$(official_apt_root)
    for prefix in deb.debian.org_debian_dists_trixie security.debian.org_debian-security_dists_trixie-security; do
        [[ -s $root/lists/${prefix}_InRelease ]] || return 1
        found=no
        for file in "$root/lists/${prefix}_main_binary-amd64_Packages" "$root/lists/${prefix}_main_binary-amd64_Packages."*; do
            [[ ! -s $file ]] || found=yes
        done
        [[ $found == yes ]] || return 1
    done
}
check_origins() {
    local output; output=$(apt_cache policy)
    awk '/^[[:space:]]*release / {
        if($0~/a=now([,[:space:]]|$)/)next
        if($0!~/o=Debian(-Security)?([,[:space:]]|$)/ || $0!~/n=trixie(-updates|-security)?([,[:space:]]|$)/)bad=1
        n++
    } END{exit(bad||n==0)}' <<< "$output" || die '软件索引未通过 Debian 13 官方来源检查，已停止。'
}
strict_update() { official_apt_prepare; apt_run --error-on=any update; check_origins; }
official_apt_recover_indexes() {
    official_apt_prepare
    if ! official_apt_ready; then strict_update; fi
}
official_apt_cleanup() {
    local root path
    root=$(official_apt_root)
    [[ -e $root || -L $root ]] || return 0
    official_apt_file_ok "$root/owner" && [[ $(cat "$root/owner") == "${S[task_id]}" ]] || die '更新暂存目录不属于本次任务，未执行清理。'
    official_apt_check_tree || die '更新暂存目录含有未知内容，未执行清理，请保留现场检查。'
    # Delete only the previously checked regular files; never recurse with rm.
    while IFS= read -r -d '' path; do rm -- "$path" || return 1; done < <(find -P "$root" -xdev -type f ! -name owner -print0)
    for path in lists/partial lists/auxfiles lists parts sourceparts preferencesparts trustedparts authparts; do
        [[ ! -d $root/$path ]] || rmdir -- "$root/$path" || return 1
    done
    rm -- "$root/owner" || return 1
    rmdir -- "$root" || return 1
    sync -f "${root%/*}"
}
# END NEXT-VPS OFFICIAL APT VIEW

apt_install() { apt_run install -y --no-remove --no-install-recommends "$@"; }
candidate_has_index() {
    local version=$1
    awk -v candidate="$version" '
        $1=="***" && NF==3 {active=($2==candidate); next}
        NF==2 && $2~/^[0-9]+$/ {active=($1==candidate); next}
        active && $1~/^[0-9]+$/ && $2~/^(https?:\/\/|mirror\+file:)/ && $3~/^trixie(-security|-updates)?\// {found=1}
        END{exit !found}'
}
check_candidate() {
    local pkg=$1 output installed_version candidate
    installed "$pkg" || die "Package is not fully installed: $pkg"
    output=$(apt_cache policy "$pkg")
    installed_version=$(awk '$1=="Installed:"{print $2}' <<< "$output")
    candidate=$(awk '$1=="Candidate:"{print $2}' <<< "$output")
    [[ -n $candidate && $candidate != '(none)' && $installed_version == "$candidate" ]] || die "Installed/Candidate mismatch: $pkg"
    candidate_has_index "$candidate" <<< "$output" || die "Installed version has no corresponding official APT package index: $pkg"
}
set_target_kernel() {
    local dependency pkg
    check_candidate "${S[kernel_meta]}"
    dependency=$(dpkg-query -W -f='${Depends}' "${S[kernel_meta]}")
    pkg=${dependency%% *}
    [[ $pkg =~ ^linux-image-(6\.12\.[a-zA-Z0-9.+~-]+-amd64)$ ]] || die 'Unexpected official kernel metapackage dependency.'
    S[target_kernel]=${BASH_REMATCH[1]}
    installed "$pkg" || die 'Target kernel package is not fully installed.'
    [[ -f /boot/vmlinuz-${S[target_kernel]} && -f /boot/initrd.img-${S[target_kernel]} && -r /boot/config-${S[target_kernel]} ]] || die 'Target kernel boot files are missing.'
    check_candidate "$pkg"
    save_state
}
safe_swap_dir() {
    local path=$1 mode
    [[ -d $path && ! -L $path && $(readlink -e -- "$path") == "$path" && $(stat -c %u -- "$path") == 0 ]] || return 1
    mode=$(stat -c %a -- "$path") || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 022) == 0 ))
}
fail2ban_table_preflight() {
    local tables status
    command -v nft >/dev/null 2>&1 || return 0
    tables=$(nft list tables) || die 'Cannot inspect existing nftables tables; no rules were flushed.'
    if grep -Eq '^table[[:space:]]+inet[[:space:]]+f2b-next-vps-setup[[:space:]]*$' <<< "$tables"; then
        die 'The reserved Fail2ban nftables table already exists; it was not modified.'
    else status=$?; [[ $status == 1 ]] || die 'Cannot inspect reserved Fail2ban table name.'; fi
}
fresh_fail2ban_preflight() {
    local file
    if installed fail2ban || systemctl is-active --quiet fail2ban.service; then
        die 'Fail2ban already exists; this fresh-system initializer does not replace an existing installation.'
    fi
    fail2ban_table_preflight
    for file in /etc/fail2ban/*.conf /etc/fail2ban/*.local /etc/fail2ban/*/* /etc/fail2ban/.[!.]* /etc/fail2ban/..?*; do
        [[ ! -e $file && ! -L $file ]] || die "Existing Fail2ban configuration: $file; nothing was overwritten."
    done
}
swap_owner_content() {
    printf 'format\t1\ntask_id\t%s\nmachine_id\t%s\nswap_uuid\t%s\nbytes\t%s\n' "${S[task_id]}" "${S[machine_id]}" "${S[swap_uuid]}" "$SWAP_BYTES"
}
swap_unit_content() {
    printf '%s\n' '# Managed by next-vps-setup v1.1' '[Unit]' 'Description=next-vps-setup low-memory disk Swap (1 GiB)' \
        '' '[Swap]' "What=$SWAP_FILE" 'Priority=10' 'TimeoutSec=90s' \
        '' '[Install]' 'WantedBy=swap.target'
}
swap_sysctl_content() { printf '%s\n' '# Managed by next-vps-setup v1.1' 'vm.swappiness = 10'; }
swap_mount_field() {
    local value
    value=$(findmnt --raw --noheadings --first-only --output "$1" --target /var/lib) || die 'Cannot inspect the Swap filesystem.'
    [[ -n $value && $value != *[[:space:]]* ]] || die 'Ambiguous Swap filesystem metadata.'
    printf '%s\n' "$value"
}
swap_filesystem_check() {
    local source options
    safe_swap_dir /var/lib && safe_swap_dir /etc/systemd/system && safe_swap_dir /etc/sysctl.d || die 'Unsafe disk Swap configuration directories.'
    [[ $(swap_mount_field FSTYPE) == ext4 ]] || die 'Automatic Swap creation supports a writable local ext4 filesystem only; no filesystem was changed.'
    source=$(swap_mount_field SOURCE); options=$(swap_mount_field OPTIONS)
    [[ $source == /dev/* && -b $source && ,$options, != *,ro,* ]] || die 'Expected a writable local ext4 block filesystem for Swap.'
}
swap_no_conflicts() {
    local mode=$1 listing file value status unit load active sub rest what
    awk -v own="$SWAP_FILE" -v allow="$mode" '
        NR==1 {if(NF!=5 || $1!="Filename" || $5!="Priority")bad=1}
        NR>1 {if(allow!="owned" || $1!=own || $2!="file")bad=1}
        END{exit bad}' /proc/swaps || die 'Existing unknown active Swap; it was not disabled or replaced.'
    awk '$0!~/^[[:space:]]*#/ && NF>=3 && $3=="swap" {bad=1} END{exit bad}' /etc/fstab || die 'Existing fstab Swap conflicts with automatic creation; it was not changed.'
    listing=$(systemctl list-unit-files --full --no-legend --no-pager) || die 'Cannot inspect persistent Swap units.'
    awk -v own="$SWAP_UNIT" -v allow="$mode" '$1~/[.]swap$/ && !(allow=="owned" && $1==own) {bad=1} END{exit bad}' <<< "$listing" || die 'Another persistent/generated Swap unit exists.'
    listing=$(systemctl list-units --all --plain --full --no-legend --no-pager) || die 'Cannot inspect loaded Swap units.'
    while read -r unit load active sub rest; do
        [[ $unit == *.swap ]] || continue
        [[ $mode == owned && $unit == "$SWAP_UNIT" ]] || die "Unexpected loaded Swap unit: $unit"
    done <<< "$listing"
    if [[ -e /sys/module/zswap/parameters/enabled ]]; then
        value=$(cat /sys/module/zswap/parameters/enabled)
        [[ $value == N || $value == n || $value == 0 ]] || die 'Existing compressed Swap cache is enabled; this disk-only policy does not change it automatically.'
    fi
    for file in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
        [[ -e $file || -L $file ]] || continue
        if [[ $mode == owned && $file == "$SWAP_SYSCTL" ]]; then
            plain_root_file "$file" && cmp -s "$file" <(swap_sysctl_content) || die 'Owned Swap sysctl configuration changed.'
            continue
        fi
        [[ -f $file && -r $file ]] || die "Cannot read sysctl configuration: $file"
        if grep -Eq '^[[:space:]]*-?vm[./]swappiness[[:space:]]*=' "$file"; then die "Existing swappiness setting conflicts: $file"
        else status=$?; [[ $status == 1 ]] || die "Cannot inspect sysctl configuration: $file"; fi
    done
}
swap_inspect_owned() {
    local file
    safe_swap_dir "$SWAP_DIR" && [[ $(stat -c %a -- "$SWAP_DIR") == 700 && $(stat -c %d -- "$SWAP_DIR") == "$(stat -c %d -- /var/lib)" ]] || die 'Unsafe or separately mounted persistent Swap directory.'
    plain_root_file "$SWAP_OWNER" && [[ $(stat -c %h -- "$SWAP_OWNER") == 1 && $(stat -c %a -- "$SWAP_OWNER") == 644 ]] &&
        cmp -s "$SWAP_OWNER" <(swap_owner_content) || die 'Disk Swap ownership record differs; no file was adopted.'
    for file in "$SWAP_DIR"/* "$SWAP_DIR"/.[!.]* "$SWAP_DIR"/..?*; do
        [[ -e $file || -L $file ]] || continue
        case $file in "$SWAP_OWNER"|"$SWAP_FILE") plain_root_file "$file" || die 'Unsafe owned Swap file.' ;; *) die "Unknown persistent Swap directory entry: $file" ;; esac
    done
}
swap_preflight() {
    local mode=$1 file free allocated=0 directory
    swap_filesystem_check
    swap_no_conflicts "$mode"
    for directory in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system; do
        [[ ! -e $directory/$SWAP_UNIT.d && ! -L $directory/$SWAP_UNIT.d ]] || die "Existing Swap unit override directory: $directory/$SWAP_UNIT.d"
        if [[ $directory != /etc/systemd/system ]]; then
            [[ ! -e $directory/$SWAP_UNIT && ! -L $directory/$SWAP_UNIT ]] || die "Another source defines the Swap unit: $directory/$SWAP_UNIT"
        fi
    done
    if [[ $mode == new ]]; then
        for file in "$SWAP_DIR" "$SWAP_SYSCTL" "$SWAP_UNIT_FILE" /etc/systemd/system/swap.target.wants/"$SWAP_UNIT"; do
            [[ ! -e $file && ! -L $file ]] || die "Reserved Swap path already exists: $file"
        done
    else
        if [[ -e $SWAP_DIR || -L $SWAP_DIR ]]; then swap_inspect_owned; fi
        if [[ -e $SWAP_UNIT_FILE || -L $SWAP_UNIT_FILE ]]; then plain_root_file "$SWAP_UNIT_FILE" && cmp -s "$SWAP_UNIT_FILE" <(swap_unit_content) || die 'Existing disk Swap unit conflicts.'; fi
    fi
    if [[ -e $SWAP_FILE || -L $SWAP_FILE ]]; then
        plain_root_file "$SWAP_FILE" && [[ ${S[swap_identity]:--} != - && $(file_identity "$SWAP_FILE") == "${S[swap_identity]}" && $(stat -c %a -- "$SWAP_FILE") == 600 && $(stat -c %h -- "$SWAP_FILE") == 1 ]] || die 'An unrecorded or changed partial Swap file remains; retain it for inspection.'
        allocated=$(stat -c %b -- "$SWAP_FILE"); allocated=$((allocated*512))
    fi
    free=$(df -Pk /var/lib | awk 'END{print $4}')
    [[ $free =~ ^[0-9]+$ ]] && ((free*1024+allocated>=SWAP_BYTES+SWAP_RESERVE_KIB*1024)) || die 'Need space for the 1 GiB Swap file plus 1 GiB filesystem reserve.'
}
swap_verify_file() {
    local blocks
    swap_inspect_owned
    plain_root_file "$SWAP_FILE" && [[ ${S[swap_identity]} != - && $(file_identity "$SWAP_FILE") == "${S[swap_identity]}" && $(stat -c %a -- "$SWAP_FILE") == 600 && $(stat -c %h -- "$SWAP_FILE") == 1 && $(stat -c %s -- "$SWAP_FILE") == "$SWAP_BYTES" ]] || die 'Owned Swap identity, size or permissions changed.'
    blocks=$(stat -c %b -- "$SWAP_FILE")
    [[ $blocks =~ ^[0-9]+$ ]] && ((blocks*512>=SWAP_BYTES)) || die 'Swap allocation is incomplete or sparse.'
    [[ $(blkid -p -s TYPE -o value -- "$SWAP_FILE") == swap && $(blkid -p -s UUID -o value -- "$SWAP_FILE") == "${S[swap_uuid]}" ]] || die 'Owned Swap signature differs.'
}
verify_swap_definition() {
    # Verify systemd's fully merged definition, including type-wide and prefix
    # drop-ins, before enabling or starting the unit. No active state is needed.
    [[ $(systemctl show "$SWAP_UNIT" -p FragmentPath --value) == "$SWAP_UNIT_FILE" && $(systemctl show "$SWAP_UNIT" -p What --value) == "$SWAP_FILE" && $(systemctl show "$SWAP_UNIT" -p Priority --value) == 10 && -z $(systemctl show "$SWAP_UNIT" -p DropInPaths --value) ]] || die 'Loaded disk Swap unit differs.'
}
verify_swap() {
    local page
    swap_filesystem_check; swap_no_conflicts owned; swap_verify_file
    plain_root_file "$SWAP_UNIT_FILE" && cmp -s "$SWAP_UNIT_FILE" <(swap_unit_content) || die 'Persistent Swap unit differs.'
    plain_root_file "$SWAP_SYSCTL" && cmp -s "$SWAP_SYSCTL" <(swap_sysctl_content) || die 'Persistent Swap parameter differs.'
    [[ $(systemctl is-enabled "$SWAP_UNIT") == enabled && -L /etc/systemd/system/swap.target.wants/$SWAP_UNIT && $(readlink -e -- /etc/systemd/system/swap.target.wants/"$SWAP_UNIT") == "$SWAP_UNIT_FILE" ]] || die 'Swap is not persistently enabled.'
    systemctl is-active --quiet "$SWAP_UNIT" || die 'Owned disk Swap is not active.'
    verify_swap_definition
    page=$(getconf PAGESIZE)
    [[ $page =~ ^[1-9][0-9]*$ ]] || die 'Cannot read system page size.'
    awk -v disk="$SWAP_FILE" -v size="$(((SWAP_BYTES-page)/1024))" 'NR>1{n++;if(NF!=5 || $1!=disk || $2!="file" || $3!=size || $5!=10)bad=1} END{exit(bad || n!=1)}' /proc/swaps || die 'Active disk Swap capacity or priority differs.'
    [[ $(sysctl -n vm.swappiness) == 10 ]] || die 'Live swappiness differs from 10.'
}
phase_swap() {
    local active=no free allocated
    if [[ ${S[swap_policy]} == skip ]]; then
        S[swap_status]=skipped; S[phase]=update; save_state
        note '实际内存大于 1GiB：不新建 Swap，保留已有内存设置。'
        return 0
    fi
    if [[ ${S[swap_status]} == pending ]]; then
        swap_preflight new
        S[swap_uuid]=$(cat /proc/sys/kernel/random/uuid); S[swap_status]=building; save_state
    fi
    swap_preflight owned
    if [[ ! -e $SWAP_DIR && ! -L $SWAP_DIR ]]; then
        mkdir -m 0700 -- "$SWAP_DIR"
        publish_config "$SWAP_OWNER" "$(swap_owner_content)"
    fi
    swap_inspect_owned
    if awk -v file="$SWAP_FILE" 'NR>1 && $1==file{found=1} END{exit !found}' /proc/swaps; then active=yes; fi
    if [[ $active == yes ]]; then
        swap_verify_file
    else
        if [[ ! -e $SWAP_FILE && ! -L $SWAP_FILE ]]; then
            [[ ${S[swap_identity]} == - ]] || die 'Recorded Swap file disappeared.'
            (set -o noclobber; : > "$SWAP_FILE")
            chmod 0600 "$SWAP_FILE"
            S[swap_identity]=$(file_identity "$SWAP_FILE"); save_state
        fi
        plain_root_file "$SWAP_FILE" && [[ $(file_identity "$SWAP_FILE") == "${S[swap_identity]}" && $(stat -c %a -- "$SWAP_FILE") == 600 && $(stat -c %h -- "$SWAP_FILE") == 1 && $(stat -c %s -- "$SWAP_FILE") -le $SWAP_BYTES ]] || die 'Partial Swap identity differs.'
        # Never overwrite an active Swap. Recheck immediately before construction.
        awk -v file="$SWAP_FILE" 'NR>1 && $1==file{bad=1} END{exit bad}' /proc/swaps || die 'Swap became active during construction.'
        dd if=/dev/zero of="$SWAP_FILE" bs=1048576 count=1024 conv=fsync status=progress
        mkswap -U "${S[swap_uuid]}" -- "$SWAP_FILE"
        swap_verify_file
    fi
    publish_config "$SWAP_UNIT_FILE" "$(swap_unit_content)"
    publish_config "$SWAP_SYSCTL" "$(swap_sysctl_content)"
    systemctl daemon-reload
    verify_swap_definition
    systemctl enable --now "$SWAP_UNIT"
    sysctl -w vm.swappiness=10
    S[swap_status]=active; dirty
    verify_swap
    S[phase]=update; save_state
    note '已启用 1GiB Swap，优先级 10、swappiness=10；稍后会重启检查是否持久生效。'
}
phase_update() {
    check_resources; strict_update
    apt_run dist-upgrade -y --no-remove
    apt_install "${S[kernel_meta]}"
    set_target_kernel
    check_ssh "${S[ssh_port]}"
    S[phase]=configure; save_state
}
publish_config() {
    local path=$1 content=$2 parent=${1%/*} tmp
    [[ -d $parent && ! -L $parent ]] || mkdir -p -- "$parent"
    [[ ! -L $parent && ! -L $path ]] || die "Configuration symlink refused: $path"
    if [[ -e $path ]]; then
        plain_root_file "$path" && cmp -s -- "$path" <(printf '%s\n' "$content") || die "Existing conflicting configuration: $path"
        return 0
    fi
    tmp=$(mktemp "$parent/.next-vps-setup-config.XXXXXX")
    printf '%s\n' "$content" > "$tmp"; chmod 0644 "$tmp"; sync -f "$tmp"
    ln -T -- "$tmp" "$path" || die "Cannot publish configuration: $path"
    rm -- "$tmp"; sync -f "$parent"
    [[ $path == "$UNIT_FILE" ]] || dirty
}
jail_content() {
    cat <<'JAIL_HEADER'
# Managed by next-vps-setup v1.1
[sshd]
enabled = true
JAIL_HEADER
    printf 'port = %s\n' "${S[ssh_port]}"
    cat <<'JAIL_BODY'
protocol = tcp
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
maxretry = 5
findtime = 600
bantime = -1
action = nftables[type=multiport, name=sshd, port="%(port)s", protocol=tcp, table=f2b-next-vps-setup]
JAIL_BODY
}
balloon_content() { printf '%s\n' '# Managed by next-vps-setup v1.1' 'blacklist virtio_balloon' 'install virtio_balloon /bin/false'; }
configure_hostname() {
    if [[ $(hostnamectl --static) != "${S[hostname]}" ]]; then hostnamectl set-hostname "${S[hostname]}"; dirty; fi
    if ! getent hosts "${S[hostname]}" >/dev/null; then
        [[ -f /etc/hosts && ! -L /etc/hosts ]] || die 'Cannot safely update local hosts mapping.'
        local tmp
        tmp=$(mktemp /etc/.next-vps-setup-hosts.XXXXXX)
        cat /etc/hosts > "$tmp"
        printf '\n127.0.1.1\t%s\n' "${S[hostname]}" >> "$tmp"
        chmod --reference=/etc/hosts "$tmp"; chown --reference=/etc/hosts "$tmp"
        sync -f "$tmp"; mv -T -- "$tmp" /etc/hosts; sync -f /etc; dirty
    fi
    [[ $(hostnamectl --static) == "${S[hostname]}" ]] && getent hosts "${S[hostname]}" >/dev/null || die 'Hostname verification failed.'
}
ntp_observe() {
    local enabled synchronized
    S[ntp_status]=unavailable
    [[ ${S[ntp_unit]} != - ]] || return 0
    if ! systemctl is-active --quiet "${S[ntp_unit]}"; then return 0; fi
    if ! enabled=$(systemctl is-enabled "${S[ntp_unit]}"); then return 0; fi
    [[ $enabled == enabled ]] || return 0
    if ! synchronized=$(timedatectl show -p NTPSynchronized --value); then return 0; fi
    case $synchronized in
        yes) S[ntp_status]=synchronized ;;
        no) S[ntp_status]=unsynchronized ;;
    esac
    return 0
}
ntp_warning() {
    if [[ ${S[ntp_status]} != synchronized ]]; then
        note '提醒：尚未完成网络校时，继续使用系统当前时间；其他步骤会继续执行。'
    fi
    return 0
}
wait_ntp() {
    local i
    for ((i=0;i<6;i++)); do
        ntp_observe
        [[ ${S[ntp_status]} != synchronized ]] || return 0
        [[ ${S[ntp_status]} != unavailable ]] || break
        sleep 5
    done
    ntp_observe
    ntp_warning
}
configure_ntp() {
    local first_attempt=no
    [[ ${S[ntp_status]} != pending ]] || first_attempt=yes
    if [[ ${S[ntp_unit]} == - ]]; then
        S[ntp_status]=unavailable; ntp_warning; save_state
        return 0
    fi
    if [[ ${S[ntp_unit]} == systemd-timesyncd.service ]]; then
        if ! systemctl restart systemd-timedated.service; then
            note '提醒：时间管理服务暂时无法重启，校时不作为必需完成条件。'
        fi
    fi
    if ! systemctl enable --now "${S[ntp_unit]}"; then
        note "提醒：无法启动校时服务 ${S[ntp_unit]}，其他步骤会继续执行。"
    fi
    dirty
    if [[ $first_attempt == yes ]]; then wait_ntp; else ntp_observe; ntp_warning; fi
    save_state
}
wait_fail2ban() {
    local i
    for ((i=0;i<30;i++)); do
        if systemctl is-active --quiet fail2ban.service && fail2ban-client ping 2>/dev/null | grep -q pong; then return 0; fi
        sleep 2
    done
    die 'Fail2ban did not become ready in 60 seconds.'
}
verify_fail2ban() {
    local value database
    wait_fail2ban
    [[ $(systemctl is-enabled fail2ban.service) == enabled ]] || die 'Fail2ban is not persistently enabled.'
    fail2ban-client status sshd
    [[ $(fail2ban-client get sshd maxretry) == 5 && $(fail2ban-client get sshd findtime) == 600 && $(fail2ban-client get sshd bantime) == -1 ]] || die 'Fail2ban SSH parameters differ from policy.'
    [[ $(fail2ban-client get sshd action nftables port) == "${S[ssh_port]}" ]] || die 'Fail2ban action uses the wrong port.'
    [[ $(fail2ban-client get sshd action nftables table) == f2b-next-vps-setup ]] || die 'Fail2ban action uses an unexpected nftables table.'
    value=$(fail2ban-client get sshd journalmatch)
    [[ $value == *'_COMM=sshd-session'* && $value == *'_SYSTEMD_UNIT=ssh.service'* ]] || die 'Fail2ban journal matching is incomplete.'
    database=$(fail2ban-client get dbfile)
    grep -Eq '(^|[[:space:]])/var/lib/fail2ban/fail2ban\.sqlite3$' <<< "$database" || die 'Fail2ban is not using the expected persistent database.'
    plain_root_file /var/lib/fail2ban/fail2ban.sqlite3 || die 'Fail2ban persistent database is missing or unsafe.'
    command -v nft >/dev/null || die 'nftables action dependency is missing.'
}
phase_configure() {
    strict_update
    apt_install curl ca-certificates kmod tzdata
    configure_hostname
    if [[ $(timedatectl show -p Timezone --value) != Asia/Kuala_Lumpur ]]; then timedatectl set-timezone Asia/Kuala_Lumpur; dirty; fi
    local actual_ntp
    actual_ntp=$(detect_ntp)
    if [[ ${S[ntp_unit]} == - ]]; then
        if [[ $actual_ntp == - ]]; then apt_install systemd-timesyncd; actual_ntp=systemd-timesyncd.service; fi
        S[ntp_unit]=$actual_ntp; save_state
    fi
    [[ $actual_ntp == "${S[ntp_unit]}" ]] || die 'NTP provider changed during initialization.'
    systemctl daemon-reload
    configure_ntp
    check_ssh "${S[ssh_port]}"
    apt_install nftables
    if [[ ! -e $JAIL && ! -L $JAIL ]]; then fail2ban_table_preflight; fi
    publish_config "$JAIL" "$(jail_content)"
    apt_install fail2ban
    fail2ban-client -t
    systemctl enable fail2ban.service
    systemctl restart fail2ban.service
    dirty; verify_fail2ban
    S[phase]=kernel; save_state
}
request_reboot() {
    local reason=$1
    [[ ${S[reboot_wait]} == none && ${S[reboot_count]} -lt 3 ]] || die 'Reboot limit or pending reboot prevents another request.'
    S[boot_before]=$(boot_id); S[reboot_count]=$((S[reboot_count]+1)); S[reboot_wait]=$reason
    save_state; sync
    nv_ui_heading "即将自动重启 · 第 ${S[reboot_count]} 次"
    note "当前阶段：$(nv_ui_stage_name "${S[phase]}")。重启后会自动继续；SSH 需要手动重连。"
    IN_REBOOT=yes
    systemctl reboot --no-block
    exit 0
}
consume_reboot() {
    [[ ${S[reboot_wait]} != none ]] || return 0
    local transition
    transition=$(boot_transition "${S[boot_before]}" "$(boot_id)" "${S[reboot_count]}" "${S[target_kernel]}" "$(uname -r)") || die 'Reboot verification failed: unexpected kernel or invalid state.'
    [[ $transition != WAIT ]] || die 'A reboot was already requested in this boot; it was not requested again.'
    S[reboot_wait]=none; save_state
}
phase_kernel() {
    if [[ $(uname -r) != "${S[target_kernel]}" ]]; then request_reboot kernel; fi
    S[phase]=balloon; save_state
}
balloon_kernel_mode() {
    local config value
    config=/boot/config-$(uname -r)
    [[ -f $config && -r $config ]] || return 1
    value=$(grep -E '^(CONFIG_VIRTIO_BALLOON=|# CONFIG_VIRTIO_BALLOON is not set$)' "$config") || return 1
    case $value in CONFIG_VIRTIO_BALLOON=m) printf 'module\n' ;; '# CONFIG_VIRTIO_BALLOON is not set') printf 'absent\n' ;; CONFIG_VIRTIO_BALLOON=y) printf 'builtin\n' ;; *) return 1 ;; esac
}
verify_balloon() {
    local mode
    mode=$(balloon_kernel_mode) || die 'Cannot read a definitive balloon kernel configuration.'
    if [[ ${S[balloon]} == module ]]; then
        [[ $mode == module ]] && cmp -s "$BALLOON_CONF" <(balloon_content) || die 'Balloon persistent configuration differs.'
        [[ $(modprobe -n -v virtio_balloon) == 'install /bin/false '* || $(modprobe -n -v virtio_balloon) == 'install /bin/false' ]] || die 'Balloon load prevention is not effective.'
    else [[ $mode == absent ]] || die 'Balloon driver state changed.'; fi
    [[ ! -d /sys/module/virtio_balloon ]] || die 'Balloon module is still loaded after reboot.'
}
phase_balloon() {
    local mode
    mode=$(balloon_kernel_mode) || die 'Cannot inspect balloon build configuration.'
    [[ $mode != builtin ]] || die 'Balloon is built into this kernel; module blacklisting cannot disable it.'
    if [[ $mode == module ]]; then
        if [[ ${S[balloon]} == pending ]]; then
            publish_config "$BALLOON_CONF" "$(balloon_content)"
            update-initramfs -u -k all
            S[balloon]=module; dirty; request_reboot balloon
        fi
    else S[balloon]=absent; save_state; fi
    verify_balloon
    S[phase]=final; save_state
}
verify_all() {
    official_apt_recover_indexes
    [[ $(uname -r) == "${S[target_kernel]}" ]] || die 'Running kernel differs from target.'
    check_candidate "${S[kernel_meta]}"; check_candidate "linux-image-${S[target_kernel]}"
    check_ssh "${S[ssh_port]}"
    [[ $(hostnamectl --static) == "${S[hostname]}" ]] && getent hosts "${S[hostname]}" >/dev/null || die 'Hostname did not persist.'
    [[ $(timedatectl show -p Timezone --value) == Asia/Kuala_Lumpur ]] || die 'Timezone did not persist.'
    ntp_observe; ntp_warning
    verify_balloon; verify_fail2ban
    cmp -s "$JAIL" <(jail_content) || die 'SSH jail persistent file differs.'
    if [[ ${S[swap_policy]} == disk1g ]]; then
        [[ ${S[swap_status]} == active || ${S[swap_status]} == verified ]] || die 'Disk Swap preparation is incomplete.'
        verify_swap
    fi
    local pkg pending
    for pkg in curl ca-certificates kmod tzdata fail2ban nftables; do check_candidate "$pkg"; done
    if [[ ${S[swap_policy]} == disk1g ]]; then check_candidate util-linux; fi
    pending=$(apt_run -s dist-upgrade --no-remove)
    if grep -q '^Inst ' <<< "$pending"; then die 'Package indexes now contain further upgrades; no success was declared.'; fi
}
snapshot_result() {
    local -a files=(/etc/hostname /etc/localtime "$JAIL") packages=(curl ca-certificates kmod tzdata fail2ban nftables "${S[kernel_meta]}" "linux-image-${S[target_kernel]}")
    [[ ${S[balloon]} != module ]] || files+=("$BALLOON_CONF")
    if [[ ${S[swap_policy]} == disk1g ]]; then files+=("$SWAP_OWNER" "$SWAP_UNIT_FILE" "$SWAP_SYSCTL"); packages+=(util-linux); fi
    S[config_hashes]=$(sha256sum -- "${files[@]}" | sha256sum | awk '{print $1}')
    S[packages]=$(dpkg-query -W -f='${binary:Package}=${Version},' "${packages[@]}")
    S[verified_boot]=$(boot_id); S[verified_at]=$(date +%s)
}
phase_final() {
    if [[ ${S[last_config_boot]} == "$(boot_id)" ]]; then request_reboot final; fi
    verify_all
    if [[ ${S[swap_policy]} == disk1g ]]; then S[swap_status]=verified; fi
    snapshot_result
    S[phase]=cleanup; S[result_status]=cleanup_pending
    save_state; write_state_to "$RESULT"
}
verify_task_files() {
    [[ -d $BASE && ! -L $BASE && $(stat -c %u "$BASE") == 0 && $(stat -c %a "$BASE") == 700 ]] || die 'Task directory is unsafe.'
    plain_root_file "$BASE/owner" && [[ $(cat "$BASE/owner") == "${S[task_id]}" ]] || die 'Task directory ownership marker does not match.'
    plain_root_file "$WORKER" && [[ $(file_sha "$WORKER") == "${S[worker_sha]}" ]] || die 'Worker identity changed.'
    local file
    for file in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
        [[ -e $file || -L $file ]] || continue
        case $file in "$WORKER"|"$STATE_FILE"|"$BASE/owner"|"$BASE/next-vps-setup.log") [[ ! -L $file && -f $file ]] || die "Unexpected task file type: $file" ;; *) die "Unknown task residual, automatic deletion refused: $file" ;; esac
    done
}
cleanup_success() {
    # The flock is on the existing /var/lib directory, never a deleted lock inode.
    # It does not interfere with ordinary directory access or APT's different locks.
    verify_all; verify_task_files
    [[ ${S[result_status]} == cleanup_pending ]] || die 'Cleanup lacks a verified receipt.'
    write_state_to "$RESULT"
    apt_run clean
    if [[ -e $UNIT_FILE || -L $UNIT_FILE ]]; then
        plain_root_file "$UNIT_FILE" && cmp -s "$UNIT_FILE" <(unit_content) || die 'Temporary unit was changed; it was not removed.'
        systemctl disable "$UNIT"
        rm -- "$UNIT_FILE"; systemctl daemon-reload
    fi
    # Functional recheck occurs before deleting any recovery source or entry.
    verify_all
    local entry=${S[entry_path]}
    if [[ -e $entry || -L $entry ]]; then
        safe_entry_path "$entry" && [[ $(file_identity "$entry") == "${S[entry_identity]}" && $(file_sha "$entry") == "${S[entry_sha]}" ]] || die 'Entry file was replaced; automatic deletion refused.'
    fi
    # Stage the notice while recovery files still exist. The login hook waits
    # for this same task's durable done/complete receipt before displaying it.
    publish_login_notice success
    official_apt_cleanup
    # Receipt is already durable: recovery after this point is cleanup-only.
    rm -- "$STATE_FILE" "$BASE/owner" "$WORKER"
    [[ ! -e $BASE/next-vps-setup.log ]] || rm -- "$BASE/next-vps-setup.log"
    rmdir -- "$BASE"
    [[ ! -e $entry ]] || rm -- "$entry"
    [[ ! -e $entry && ! -L $entry && ! -e $BASE && ! -e $UNIT_FILE ]] || die 'Cleanup incomplete; retained receipt allows cleanup recovery.'
    S[phase]='done'; S[result_status]=complete; S[failed]=no
    write_state_to "$RESULT"
    nv_ui_heading '初始化已完成 · 重启核验通过'
    note "当前内核：${S[target_kernel]}；SSH 端口：${S[ssh_port]}；结果：$RESULT"
}
unit_content() {
    cat <<'UNIT_CONTENT'
[Unit]
Description=next-vps-setup initialization and boot verification
Wants=network-online.target
After=network-online.target ssh.service
ConditionPathExists=/var/lib/next-vps-setup/next-vps-setup-state.tsv

[Service]
Type=oneshot
ExecStart=/bin/bash /var/lib/next-vps-setup/next-vps-setup.sh --worker
TimeoutStartSec=infinity
Restart=no
StandardInput=null
StandardOutput=append:/var/lib/next-vps-setup/next-vps-setup.log
StandardError=append:/var/lib/next-vps-setup/next-vps-setup.log
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT_CONTENT
}
on_worker_error() {
    local code=${1:-1}
    trap - ERR EXIT TERM HUP INT
    if [[ ${IN_REBOOT:-no} == yes && $code == 143 ]]; then exit 0; fi
    [[ $code != 0 ]] || code=1
    nv_ui_heading '初始化未完成 · 已停止自动执行' >&2
    printf '出错阶段：%s\n查看原因：tail -n 100 %s/next-vps-setup.log\n修复后恢复：bash %s --resume\n' "$(nv_ui_stage_name "${S[phase]:-unknown}")" "$BASE" "${S[entry_path]:-/root/next-vps-setup.sh}" >&2
    if [[ -n ${S[phase]:-} ]]; then
        if [[ ${S[result_status]:-} == complete ]]; then S[phase]=cleanup; S[result_status]=cleanup_pending; fi
        S[failed]=yes
        if [[ -d $BASE ]]; then save_state || true; fi
        if write_state_to "$RESULT"; then
            publish_login_notice failure || printf '%s\n' '提醒：首次登录通知未能保存，请使用结果查询命令查看失败状态。' >&2
        fi
    fi
    exit "$code"
}
worker_main() {
    [[ $0 == "$WORKER" ]] || die 'Worker must run from its managed path.'
    plain_root_file "$STATE_FILE" && parse_state "$STATE_FILE" || die 'Invalid or unsafe state file.'
    [[ ${S[machine_id]} == "$(cat /etc/machine-id)" ]] || die 'State belongs to another machine.'
    [[ ${S[failed]} == no ]] || die 'Previous failure requires repair and an explicit --resume; no automatic retry.'
    trap 'on_worker_error "$?"' ERR
    # Explicit die also runs the EXIT trap so failures cannot be retried at boot.
    trap 'code=$?; if ((code!=0)); then on_worker_error "$code"; fi' EXIT
    trap 'on_worker_error 143' TERM
    trap 'on_worker_error 129' HUP
    trap 'on_worker_error 130' INT
    check_os; verify_task_files
    consume_reboot
    while :; do
        nv_ui_progress "${S[phase]}"
        case ${S[phase]} in
            swap) phase_swap ;; update) phase_update ;; configure) phase_configure ;; kernel) phase_kernel ;;
            balloon) phase_balloon ;; final) phase_final ;;
            cleanup) cleanup_success; return 0 ;; "done") return 0 ;;
            *) die 'Unknown stage.' ;;
        esac
    done
}
print_status() {
    nv_ui_heading "next-vps-setup $VERSION · 初始化状态"
    printf '当前阶段：%s\n机器名：%s\nSSH 端口：%s\n目标内核：%s\n已请求重启：%s 次\n' "$(nv_ui_stage_name "${S[phase]}")" "${S[hostname]}" "${S[ssh_port]}" "${S[target_kernel]}" "${S[reboot_count]}"
    if [[ ${S[failed]} == yes ]]; then
        printf '%s\n' '结果：未完成，任务已停止。请先查看日志，再使用同一版本恢复。'
        printf '  tail -n 100 %s/next-vps-setup.log\n' "$BASE"
    elif [[ ${S[result_status]} == complete ]]; then
        printf '%s\n' '结果：初始化完成，重启核验通过。'
    elif [[ ${S[result_status]} == cleanup_pending ]]; then
        printf '%s\n' '结果：配置核验通过，任务文件尚未清理完成。请使用同一版本 --resume。'
    else printf '%s\n' '结果：尚未完成。后台可能仍在执行，请查看日志。'; fi
    if [[ ${S[ntp_status]:-pending} == unsynchronized || ${S[ntp_status]:-pending} == unavailable ]]; then
        printf '%s\n' '提醒：验收时尚未完成网络校时；系统继续使用当前时间。'
    fi
}
launch_worker() {
    # Once a task exists, a failed systemd handoff is a task failure too.
    trap 'on_worker_error "$?"' ERR
    trap 'code=$?; if ((code!=0)); then on_worker_error "$code"; fi' EXIT
    trap 'on_worker_error 143' TERM; trap 'on_worker_error 129' HUP; trap 'on_worker_error 130' INT
    plain_root_file "$UNIT_FILE" && cmp -s "$UNIT_FILE" <(unit_content) || die 'Temporary service identity differs; it was not started.'
    systemctl daemon-reload || die 'Cannot reload the initialization service definition.'
    [[ $(systemctl show "$UNIT" -p FragmentPath --value) == "$UNIT_FILE" && -z $(systemctl show "$UNIT" -p DropInPaths --value) ]] || die 'Merged initialization service definition has an unexpected source or overrides; it was not started.'
    systemctl enable "$UNIT" || die 'Cannot enable initialization after reboot.'
    systemctl reset-failed "$UNIT" || die 'Cannot reset the initialization service failure.'
    write_state_to "$RESULT"
    flock -u 9 || die 'Cannot release the initialization handoff lock.'
    exec 9<&- || die 'Cannot close the initialization handoff lock.'
    systemctl start --no-block "$UNIT" || die 'Cannot submit the initialization start request.'
    trap - ERR EXIT TERM HUP INT
    nv_ui_launch "next-vps-setup $VERSION" '5–10' "$RESULT" "$BASE/next-vps-setup.log"
}
prepare_cleanup_recovery() {
    local entry=$1 file
    [[ ${S[phase]} == cleanup && ${S[result_status]} == cleanup_pending ]] || die 'Receipt is not a cleanup recovery point.'
    safe_entry_path "$entry" && [[ $(file_sha "$entry") == "${S[worker_sha]}" ]] || die 'Cleanup recovery requires the same root-owned script version.'
    [[ $entry == "${S[entry_path]}" ]] || die 'For cleanup recovery, upload the same script to the original entry path shown in the receipt.'
    if [[ -e $BASE || -L $BASE ]]; then
        [[ -d $BASE && ! -L $BASE && $(stat -c %u "$BASE") == 0 && $(stat -c %a "$BASE") == 700 ]] || die 'Unsafe task directory.'
        for file in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
            [[ -e $file || -L $file ]] || continue
            case $file in "$WORKER"|"$STATE_FILE"|"$BASE/owner"|"$BASE/next-vps-setup.log") plain_root_file "$file" || die 'Unsafe cleanup residual.' ;; *) die "Unknown cleanup residual: $file" ;; esac
        done
        if [[ -e $BASE/owner ]]; then [[ $(cat "$BASE/owner") == "${S[task_id]}" ]] || die 'Task marker differs from receipt.'; fi
        if [[ -e $WORKER ]]; then [[ $(file_sha "$WORKER") == "${S[worker_sha]}" ]] || die 'Worker differs from receipt.'; fi
    else mkdir -m 0700 -- "$BASE"; fi
    if [[ -e $UNIT_FILE || -L $UNIT_FILE ]]; then
        plain_root_file "$UNIT_FILE" && cmp -s "$UNIT_FILE" <(unit_content) || die 'Temporary service differs from this version.'
    fi
    # Only an explicit same-version --resume can adopt this freshly uploaded copy.
    S[entry_identity]=$(file_identity "$entry"); S[entry_sha]=$(file_sha "$entry"); S[failed]=no
    printf '%s\n' "${S[task_id]}" > "$BASE/owner"
    [[ -e $WORKER ]] || install -m 0700 -- "$entry" "$WORKER"
    save_state
    [[ -e $UNIT_FILE ]] || publish_config "$UNIT_FILE" "$(unit_content)"
    launch_worker
}
initialize_task() {
    local entry=$1 name port meta owner pkg hash memory
    safe_entry_path "$entry" || die 'Upload a root-owned, non-symlink copy under /root, not writable by other users.'
    [[ ! -e $BASE && ! -L $BASE && ! -e $UNIT_FILE && ! -L $UNIT_FILE ]] || die 'Unknown task files exist; no files were overwritten.'
    [[ ! -e $JAIL && ! -L $JAIL && ! -e $BALLOON_CONF && ! -L $BALLOON_CONF ]] || die 'Existing initialization configuration found; this entry is for a fresh system.'
    fresh_fail2ban_preflight
    [[ -t 0 ]] || die 'First run requires an interactive terminal.'
    nv_ui_heading "next-vps-setup $VERSION · Debian 13 初始化"
    printf '%s\n\n' '将更新官方软件包、配置基础防护，并自动重启验收。' 'SSH 账号、密码、端口和认证方式保持现有配置。' '网络校时不可用时会提醒并继续。请先确认备份和商家控制台可用。'
    printf '机器名（例如 hk-vps）: '; IFS= read -r name
    validate_hostname "$name" || die '机器名格式无效。请使用字母、数字、短横线或点，不要包含空格。'
    printf '当前实际 SSH 端口（仅核验，不修改）: '; IFS= read -r port
    validate_port "$port" || die 'SSH 端口无效。请输入 1 到 65535 的数字。'
    check_ssh "$port"; check_sources; check_resources
    case $(uname -r) in *-cloud-amd64) meta=linux-image-cloud-amd64 ;; *-amd64) meta=linux-image-amd64 ;; *) die 'Unrecognized kernel series.' ;; esac
    pkg=linux-image-$(uname -r)
    installed "$pkg" || die 'Running kernel is not owned by the expected Debian kernel package.'
    owner=$(dpkg-query -W -f='${Maintainer}' "$pkg")
    [[ $owner == *'Debian Kernel Team'* ]] || die 'Unknown kernel package maintainer.'
    memory=$(memtotal); memory_policy "$memory" >/dev/null || die 'Invalid memory size.'
    if (( memory <= 1048576 )); then swap_preflight new; fi
    hash=$(file_sha "$entry")
    S=([format]=3 [task_id]="$(cat /proc/sys/kernel/random/uuid)" [machine_id]="$(cat /etc/machine-id)"
       [hostname]="$name" [ssh_port]="$port" [kernel_meta]="$meta" [target_kernel]=- [ntp_unit]="$(detect_ntp)"
       [balloon]=pending [swap_policy]="$(memory_policy "$memory")" [swap_status]=pending [swap_uuid]=- [swap_identity]=- [mem_kib]="$memory" [phase]=swap
       [boot_before]=- [last_config_boot]="$(boot_id)" [reboot_count]=0 [reboot_wait]=none [failed]=no
       [entry_path]="$entry" [entry_identity]="$(file_identity "$entry")" [entry_sha]="$hash" [worker_sha]="$hash"
       [ssh_policy_sha]="$(ssh_policy_sha)" [result_status]=running [verified_boot]=- [verified_at]=0 [config_hashes]=- [packages]=- [ntp_status]=pending)
    mkdir -m 0700 -- "$BASE"
    printf '%s\n' "${S[task_id]}" > "$BASE/owner"
    install -m 0700 -- "$entry" "$WORKER"
    [[ $(file_sha "$WORKER") == "$hash" && $(file_sha "$entry") == "$hash" ]] || die 'Entry changed during preparation.'
    save_state; write_state_to "$RESULT"
    publish_config "$UNIT_FILE" "$(unit_content)"
    launch_worker
}

main() {
    local mode=${1:-start} entry
    (( $# <= 1 )) || die 'Use no arguments, --status, or --resume.'
    case $mode in start|--status|--resume|--worker) ;; --help) printf '%s\n' "next-vps-setup $VERSION" '以 root 运行：bash /root/next-vps-setup.sh [--status|--resume]' '无参数开始初始化；--status 查看状态；修复失败原因后用 --resume 继续。'; return 0 ;; *) die '参数无效。使用 --help 查看用法。' ;; esac
    [[ $(id -u) == 0 ]] || die 'Root is required.'
    if [[ $mode == --status ]]; then
        if [[ -e $STATE_FILE || -L $STATE_FILE ]]; then
            plain_root_file "$STATE_FILE" && parse_state "$STATE_FILE" || die 'Invalid existing state.'
        elif [[ -e $RESULT || -L $RESULT ]]; then
            plain_root_file "$RESULT" && parse_state "$RESULT" || die 'Invalid existing receipt.'
        else die 'No existing task or receipt.'; fi
        [[ ${S[machine_id]} == "$(cat /etc/machine-id)" ]] || die 'State belongs to another machine.'
        print_status; return 0
    fi
    if [[ $mode != --worker ]]; then check_os; fi
    # Directory inode is stable; no temporary lock file survives or is unlinked.
    exec 9</var/lib
    flock -n 9 || die 'Another initialization process is running.'
    if [[ $mode == --worker ]]; then worker_main; return; fi
    entry=$(readlink -e -- "$0") || die 'Execute a regular local file, not stdin or a pipe.'
    if [[ -e $STATE_FILE || -L $STATE_FILE ]]; then
        plain_root_file "$STATE_FILE" && parse_state "$STATE_FILE" || die 'Unsupported or invalid task state; this version cannot resume a different release. No state was changed.'
        [[ ${S[machine_id]} == "$(cat /etc/machine-id)" ]] || die 'State belongs to another machine.'
        print_status
        if [[ $mode == --resume ]]; then
            safe_entry_path "$entry" && [[ $entry == "${S[entry_path]}" && $(file_sha "$entry") == "${S[worker_sha]}" ]] || die '恢复任务需要原路径、相同内容的脚本文件。'
            if [[ ${S[phase]} == cleanup ]]; then prepare_cleanup_recovery "$entry"; return 0; fi
            verify_task_files
            S[entry_identity]=$(file_identity "$entry"); S[entry_sha]=$(file_sha "$entry")
            S[failed]=no; save_state
            [[ -e $UNIT_FILE ]] || publish_config "$UNIT_FILE" "$(unit_content)"
            launch_worker
        fi
        return 0
    fi
    if [[ -e $RESULT || -L $RESULT ]]; then
        plain_root_file "$RESULT" && parse_state "$RESULT" || die 'Unsupported or invalid completion receipt; this fresh-install version does not migrate older releases.'
        [[ ${S[machine_id]} == "$(cat /etc/machine-id)" ]] || die 'Receipt belongs to another machine.'
        print_status
        if [[ ${S[result_status]} == complete ]]; then printf '%s\n' '这台机器已完成初始化，本次没有重复修改系统。需要更新内核时，请使用内核维护工具。'; return 0; fi
        if [[ $mode == --resume ]]; then prepare_cleanup_recovery "$entry"; return 0; fi
        die 'Cleanup was interrupted after its durable receipt. Retain this receipt and inspect remaining task files before cleanup recovery.'
    fi
    [[ $mode == start ]] || die 'No existing task or receipt.'
    [[ $0 == /* && ! -L $0 && -f $0 ]] || die 'Use bash followed by an absolute regular file under /root.'
    initialize_task "$entry"
}
main "$@"
