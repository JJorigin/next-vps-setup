#!/bin/bash
# next-vps-setup v2.0 -- local-file installation, root, Debian 13 amd64 VM.
# Run: bash /root/next-vps-setup.sh
# Inspect: bash /root/next-vps-setup.sh --status
# Retry after repairing a failure: bash /root/next-vps-setup.sh --resume
# No passwords, SSH configuration changes, TCP tuning or third-party repositories.
# Fresh systems only. New disk Swap: MemTotal rounded up to GiB, swappiness 10.

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
KIB_PER_GIB=1048576
BYTES_PER_GIB=1073741824
SWAP_RESERVE_KIB=$KIB_PER_GIB
SWAP_PREPARE_KIB=16384
SWAP_MAX_PAGES=4294967295
VERSION=2.0
declare -A S=()
IN_REBOOT=no
BOOTSTRAP_BASE_ID=
BOOTSTRAP_TEMP=
BOOTSTRAP_TEMP_ID=

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
        swap) printf '检查和准备交换空间' ;;
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
    nv_ui_heading "$title · 后台任务已提交"
    printf '%s\n' \
        '  请留意：任务会自动重启，SSH 连接会断开。' \
        '  SSH 不会自动重连，需要使用原账号和端口手动连接。' \
        "  首次断线后，可先等待约 $minutes 分钟再连接。" \
        '  下载或启动较慢时会更久，请勿仅凭等待时间判断完成。' \
        '' \
        '  成功或失败后，通过 SSH 直接登录 root（登录 Shell 为 Bash）会显示结果。' \
        '  此提示显示一次后自动清理；任务仍在执行时不会报成功。' \
        '' \
        '  如未看到登录提示，查看任务结果：' "    cat $receipt" \
        '  执行中的详细进度：' "    tail -f $log"
    printf '%s\n\n' '============================================================'
}
nv_ui_stopped() {
    nv_ui_heading '操作已停止 · 本次任务尚未完成'
    printf '%s\n' '请保留下方原因。若已有任务记录，请同时保留原脚本和日志，处理后再恢复。'
    printf '原因：%s\n' "$*"
}
# END EMBEDDED user-interface

# BEGIN EMBEDDED ssh-notice
# BEGIN NEXT_VPS_SSH_NOTICE
# Embedded one-time root SSH login notice. This fragment only defines functions.
# API: nv_notice_install APP success|failure TASK_UUID STAGE NTP_STATUS ENTRY_PATH [SWAP_POLICY]
# Tests may override the root directories and helper functions before render.

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
# Frozen renderer input for comparing old hooks as data. V2 hooks never call it.
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
nv_notice_lock_dir_ok() {
    local path=$1 mode
    [[ $path =~ ^/[a-zA-Z0-9_./-]+$ && $path != *'/../'* && $path != */.. ]] || return 1
    nv_notice_safe_dir "$path" || return 1
    mode=$(stat -c %a -- "$path") || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 077) == 0 ))
}
nv_notice_lock() {
    nv_notice_lock_dir_ok "$NV_NOTICE_LOCK_DIR" || return 1
    exec 8<"$NV_NOTICE_LOCK_DIR" || return 1
    command flock -x "$@" 8
}
nv_notice_consume_v2() (
    nv_notice_is_root || exit 0
    [[ -n ${SSH_CONNECTION:-} && $- == *i* ]] || exit 0
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
    nv_notice_paths || exit 0
    nv_notice_safe_dir "$NV_NOTICE_PROFILE_DIR" && nv_notice_safe_dir "$NV_NOTICE_DATA_ROOT" || { nv_notice_warn '通知父目录身份异常'; exit 0; }
    # Never wait behind a writer during login. A later login can read the notice.
    nv_notice_lock -n || exit 0
    [[ -e $NV_NOTICE_HOOK || -L $NV_NOTICE_HOOK ]] || exit 0
    [[ $(nv_notice_id "$NV_NOTICE_HOOK") == "$NV_NOTICE_HOOK_ID" ]] || exit 0
    nv_notice_plain "$NV_NOTICE_HOOK" || { nv_notice_warn '通知入口身份异常'; exit 0; }
    nv_notice_terminal || exit 0
    if [[ -e $NV_NOTICE_DIR || -L $NV_NOTICE_DIR ]]; then
        nv_notice_validate_dir || { nv_notice_warn '通知内容或目录已变化，已拒绝显示和删除'; exit 0; }
        if [[ -e $NV_NOTICE_PENDING ]]; then
            mv -T -- "$NV_NOTICE_PENDING" "$NV_NOTICE_CLAIMED" || { nv_notice_warn '无法标记本次通知'; exit 0; }
            sync -f "$NV_NOTICE_DIR" || { nv_notice_warn '通知标记未能持久保存'; exit 0; }
            cat -- "$NV_NOTICE_CLAIMED" || { nv_notice_warn '通知输出未完成'; exit 0; }
        fi
    fi
    nv_notice_cleanup_locked || nv_notice_warn "通知文件尚未清理完成：$NV_NOTICE_HOOK"
    exit 0
)
nv_notice_render_hook() {
    local format=${1:-2}
    local -a shared=(nv_notice_is_root nv_notice_owner nv_notice_id nv_notice_sha nv_notice_warn nv_notice_plain
        nv_notice_safe_dir nv_notice_paths nv_notice_terminal nv_notice_validate_dir nv_notice_cleanup_locked)
    printf '# next-vps-ssh-notice %s\n' "$format" || return 1
    printf '# app\t%s\n# task\t%s\n# generation\t%s\n# directory_id\t%s\n# text_id\t%s\n# text_sha\t%s\n# hook_id\t%s\n# kind\t%s\n' \
        "$NV_NOTICE_APP" "$NV_NOTICE_TASK" "$NV_NOTICE_GENERATION" "$NV_NOTICE_DIR_ID" "$NV_NOTICE_TEXT_ID" "$NV_NOTICE_TEXT_SHA" "$NV_NOTICE_HOOK_ID" "$NV_NOTICE_KIND" || return 1
    # /etc/profile.d is shared with POSIX login shells. This complete POSIX
    # command returns before a non-Bash shell reads any Bash-specific grammar.
    printf '[ -n "${BASH_VERSION:-}" ] || return 0\n(\n' || return 1
    printf 'NV_NOTICE_APP=%q\nNV_NOTICE_TASK=%q\nNV_NOTICE_GENERATION=%q\nNV_NOTICE_DIR_ID=%q\nNV_NOTICE_TEXT_ID=%q\nNV_NOTICE_TEXT_SHA=%q\nNV_NOTICE_HOOK_ID=%q\nNV_NOTICE_KIND=%q\nNV_NOTICE_PROFILE_DIR=%q\nNV_NOTICE_DATA_ROOT=%q\n' \
        "$NV_NOTICE_APP" "$NV_NOTICE_TASK" "$NV_NOTICE_GENERATION" "$NV_NOTICE_DIR_ID" "$NV_NOTICE_TEXT_ID" "$NV_NOTICE_TEXT_SHA" "$NV_NOTICE_HOOK_ID" "$NV_NOTICE_KIND" "$NV_NOTICE_PROFILE_DIR" "$NV_NOTICE_DATA_ROOT" || return 1
    if [[ $format == 1 ]]; then
        declare -f "${shared[@]}" nv_notice_consume || return 1
        printf 'nv_notice_consume\n)\n'
    else
        printf 'NV_NOTICE_LOCK_DIR=%q\n' "$NV_NOTICE_LOCK_DIR" || return 1
        declare -f "${shared[@]}" nv_notice_lock_dir_ok nv_notice_lock nv_notice_consume_v2 || return 1
        printf 'nv_notice_consume_v2\n)\n'
    fi
}
nv_notice_load_existing() {
    local first key value extra format n=0
    nv_notice_plain "$NV_NOTICE_HOOK" || return 1
    IFS= read -r first < "$NV_NOTICE_HOOK" || return 1
    case $first in
        '# next-vps-ssh-notice 1') format=1 ;;
        '# next-vps-ssh-notice 2') format=2 ;;
        *) return 1 ;;
    esac
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
    cmp -s "$NV_NOTICE_HOOK" <(nv_notice_render_hook "$format") || return 1
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
    local kind=$1 stage=$2 ntp=$3 entry=$4 swap=${5:-not-recorded} result log title
    result=/var/lib/$NV_NOTICE_APP-result.tsv
    if [[ $NV_NOTICE_APP == next-vps-setup ]]; then log=/var/lib/next-vps-setup/next-vps-setup.log; title='VPS 初始化'
    else log=/var/lib/next-vps-kernel-update/run.log; title='内核维护'; fi
    printf '\n╭──────────────────────────────────────────────╮\n' || return 1
    if [[ $kind == success ]]; then
        printf '  ✓ %s已完成\n' "$title" || return 1
        printf '  状态：成功；必需步骤和最终核查已通过，可继续使用服务器。\n' || return 1
    else
        printf '  ✗ %s已停止\n' "$title" || return 1
        printf '  状态：失败，任务未完成，请先查看原因。\n  出错阶段：%s\n' "$(nv_notice_stage_name "$stage")" || return 1
    fi
    if [[ $ntp == unsynchronized || $ntp == unavailable ]]; then
        printf '  ⚠ 时间同步警告：尚未确认同步，沿用系统当前时间。\n' || return 1
    fi
    if [[ $kind == success ]]; then
        case $swap in
            disk) printf '  磁盘 Swap：重启核验通过。\n' || return 1 ;;
            preserve) printf '  Swap：已保留系统原有配置。\n' || return 1 ;;
            skip-space) printf '  ⚠ Swap：磁盘空闲不足，本次跳过新建。\n' || return 1 ;;
            skip-filesystem) printf '  ⚠ Swap：文件系统不支持自动创建，本次跳过新建。\n' || return 1 ;;
        esac
        printf '  如需查看详细记录：\n    cat %s\n' "$result" || return 1
    else
        printf '  下一步：查看失败详情。\n    tail -n 100 %s\n' "$log" || return 1
        printf '  文件日志缺失时可查看服务启动记录。\n    journalctl -u %s.service -n 100 --no-pager\n' "$NV_NOTICE_APP" || return 1
        printf '  修复原因后，使用同版本文件恢复：\n    bash %s --resume\n' "$entry" || return 1
        printf '  如入口已被清理，先上传同版本脚本到上述原路径。\n' || return 1
    fi
    printf '  此为一次性通知；读取后自动清理通知文件。\n╰──────────────────────────────────────────────╯\n\n'
}
nv_notice_install() (
    set -Eeuo pipefail
    export LC_ALL=C
    umask 077
    local kind=${2:-} task=${3:-} stage=${4:-} ntp=${5:-} entry=${6:-} swap=${7:-not-recorded}
    local temp_dir= temp_hook= published_dir=no published_hook=no code first
    (( $#==6 || $#==7 )) || { printf 'NOTICE_ERROR: invalid argument count\n' >&2; exit 1; }
    NV_NOTICE_APP=$1
    NV_NOTICE_PROFILE_DIR=${NV_NOTICE_PROFILE_DIR:-/etc/profile.d}
    NV_NOTICE_DATA_ROOT=${NV_NOTICE_DATA_ROOT:-/var/lib}
    NV_NOTICE_LOCK_DIR=${NV_NOTICE_LOCK_DIR:-/root}
    nv_notice_is_root && nv_notice_paths || { printf 'NOTICE_ERROR: root and recognized application required\n' >&2; exit 1; }
    [[ $kind == success || $kind == failure ]] && nv_notice_uuid "$task" || { printf 'NOTICE_ERROR: only terminal states are accepted\n' >&2; exit 1; }
    [[ $stage =~ ^[a-z][a-z0-9_-]{0,31}$ && ( $ntp == synchronized || $ntp == unsynchronized || $ntp == unavailable || $ntp == not-recorded ) ]] || { printf 'NOTICE_ERROR: invalid status fields\n' >&2; exit 1; }
    case $swap in
        not-recorded) ;;
        disk|preserve|skip-space|skip-filesystem)
            [[ $NV_NOTICE_APP == next-vps-setup && $kind == success ]] || exit 1 ;;
        *) exit 1 ;;
    esac
    [[ $entry == /root/*.sh && $entry =~ ^/root/[a-zA-Z0-9_./-]+\.sh$ && $entry != *'/../'* && $entry != *'/./'* ]] || { printf 'NOTICE_ERROR: invalid entry path\n' >&2; exit 1; }
    nv_notice_safe_dir "$NV_NOTICE_PROFILE_DIR" && nv_notice_safe_dir "$NV_NOTICE_DATA_ROOT" || { printf 'NOTICE_ERROR: unsafe parent directory\n' >&2; exit 1; }
    nv_notice_lock -w 5 || { printf 'NOTICE_ERROR: 无法获取 root 通知锁\n' >&2; exit 1; }
    # Coordinate with an old hook reader only while replacing a V1 hook.
    if nv_notice_plain "$NV_NOTICE_HOOK" && IFS= read -r first < "$NV_NOTICE_HOOK" && [[ $first == '# next-vps-ssh-notice 1' ]]; then
        exec 7<"$NV_NOTICE_PROFILE_DIR" || exit 1
        command flock -x -w 5 7 || { printf 'NOTICE_ERROR: 旧版通知仍被占用，已保留\n' >&2; exit 1; }
    fi
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
    nv_notice_text "$kind" "$stage" "$ntp" "$entry" "$swap" > "$temp_dir/notice.txt" || exit 1
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
# BEGIN EMBEDDED task-lock
# Shared mutex for the two systemd tasks. The directory inode lasts until reboot.
nv_task_lock() {
    local mode=$1 lock=/run/next-vps-task.lock parent_mode
    [[ -d /run && ! -L /run && $(stat -c %u -- /run) == 0 ]] || die '任务锁的上级目录不安全。'
    parent_mode=$(stat -c %a -- /run) || die '无法检查任务锁的上级目录。'
    [[ $parent_mode =~ ^[0-7]{3,4}$ ]] && (( (8#$parent_mode & 022) == 0 )) || die '任务锁的上级目录可被其他用户修改。'
    if [[ ! -e $lock && ! -L $lock ]]; then
        # A read-only check can proceed when there is no active mutex yet.
        [[ $mode != --check ]] || return 0
        mkdir -m 0700 -- "$lock" 2>/dev/null || [[ -d $lock ]] || die '无法创建运行时任务锁。'
    fi
    [[ -d $lock && ! -L $lock && $(stat -c '%u:%a' -- "$lock") == 0:700 ]] || die '运行时任务锁的归属或权限不安全。'
    exec 9<"$lock" || die '无法打开运行时任务锁。'
    case $mode in
        --worker) flock -x -w 30 9 || die '后台服务未能取得任务锁。请查看 systemd 服务日志。' ;;
        --check) flock -s -n 9 || die '当前有任务正在运行，请稍后再检查。' ;;
        *) flock -x -n 9 || die '已有初始化或内核维护任务正在运行。' ;;
    esac
}

nv_task_check_resume() {
    local unit=$1 active
    active=$(systemctl show "$unit" -p ActiveState --value) || die '无法确认后台服务是否已经停止。'
    case $active in
        inactive|failed) ;;
        *) die '后台服务仍在处理当前任务，请查看状态，稍后再恢复。' ;;
    esac
}

nv_task_show_unit_failure() {
    local unit=$1
    systemctl is-failed --quiet "$unit" || return 1
    printf '结果：后台服务已失败。回执可能尚未更新，请查看服务日志。\n  journalctl -u %s -n 80 --no-pager\n' "$unit"
}

nv_task_require_unit_definition() {
    local unit=$1 expected=$2 fragment dropins
    fragment=$(systemctl show "$unit" -p FragmentPath --value) &&
        dropins=$(systemctl show "$unit" -p DropInPaths --all) ||
        die "无法读取 $unit 的 systemd 生效配置。"
    [[ $fragment == "$expected" && $dropins == DropInPaths= ]] ||
        die "$unit 的来源或覆盖配置与本任务不一致。"
}

# Check the normal Debian SSH boot path without changing its configuration.
nv_task_require_ssh_boot() {
    local unit_dir=${1:-/etc/systemd/system} ssh_dir=${2:-/etc/ssh} state target fragment link socket_state socket_active
    [[ ! -e $ssh_dir/sshd_not_to_be_run && ! -L $ssh_dir/sshd_not_to_be_run ]] ||
        die 'Debian 的 SSH 禁用标记仍存在，自动重启后可能无法登录。'
    systemctl is-active --quiet ssh.service || die 'ssh.service 当前未运行。'
    state=$(systemctl is-enabled ssh.service) && [[ $state == enabled ]] || die 'ssh.service 未设置为开机启动。'
    target=$(systemctl get-default) || die '无法读取 systemd 默认启动目标。'
    [[ $target == multi-user.target || $target == graphical.target ]] || die '默认启动目标不支持自动重启验收。'
    fragment=$(systemctl show ssh.service -p FragmentPath --value) || die '无法读取 SSH 服务单元路径。'
    fragment=$(readlink -e -- "$fragment") || die '无法解析 SSH 服务单元路径。'
    link=$unit_dir/multi-user.target.wants/ssh.service
    [[ -L $link && $(readlink -e -- "$link") == "$fragment" ]] || die '缺少有效的 SSH 开机启动链接。'
    socket_state=$(systemctl is-enabled ssh.socket 2>/dev/null) || true
    if [[ -z $socket_state ]]; then
        socket_state=$(systemctl show ssh.socket -p LoadState --value) || die '无法读取 ssh.socket 的状态。'
    fi
    case $socket_state in disabled|masked|not-found) ;; *) die 'ssh.socket 已启用或无法核验其启动状态。' ;; esac
    if [[ $socket_state != not-found ]]; then
        socket_active=$(systemctl show ssh.socket -p ActiveState --value) || die '无法确认 ssh.socket 的运行状态。'
        [[ $socket_active == inactive || $socket_active == failed ]] || die '此工具要求 ssh.service 直接监听 SSH 端口。'
    fi
}
# END EMBEDDED task-lock

die() { nv_ui_stopped "$*" >&2; exit 1; }
note() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
publish_login_notice() {
    local kind=$1 ntp=${S[ntp_status]:-not-recorded} swap=not-recorded
    case $ntp in synchronized|unsynchronized|unavailable) ;; *) ntp=not-recorded ;; esac
    if [[ $kind == success ]]; then swap=${S[swap_policy]}; fi
    NV_NOTICE_LOCK_DIR=/root nv_notice_install next-vps-setup "$kind" "${S[task_id]}" "${S[phase]}" "$ntp" "${S[entry_path]}" "$swap"
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
kernel_meta_for_abi() {
    local abi=$1
    # Official Debian 13 stable ABIs use either an early numeric ABI suffix
    # or the +deb13[.N] form. Do not silently replace another kernel flavour.
    if [[ $abi =~ ^6\.12\.[0-9]+(-[0-9]+|\+deb13(\.[0-9]+)?)?-cloud-amd64$ ]]; then
        printf 'linux-image-cloud-amd64\n'
    elif [[ $abi =~ ^6\.12\.[0-9]+(-[0-9]+|\+deb13(\.[0-9]+)?)?-amd64$ ]]; then
        printf 'linux-image-amd64\n'
    else
        return 1
    fi
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
swap_target_bytes() {
    local value=$1
    [[ $value =~ ^[1-9][0-9]{0,14}$ ]] || return 1
    # At most 15 digits of KiB keeps the result inside signed 64-bit arithmetic.
    printf '%s\n' "$(((1 + (value - 1) / KIB_PER_GIB) * BYTES_PER_GIB))"
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
safe_state_parent() {
    local path=$1 mode
    while :; do
        [[ -d $path && ! -L $path && $(stat -c %u -- "$path") == 0 ]] || return 1
        mode=$(stat -c %a -- "$path") || return 1
        [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 022) == 0 )) || return 1
        [[ $path != / ]] || break
        path=${path%/*}; [[ -n $path ]] || path=/
    done
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
        format) [[ $value == 3 || $value == 4 ]] ;;
        task_id) validate_boot_id "$value" ;;
        machine_id) [[ $value =~ ^[a-f0-9]{32}$ ]] ;;
        hostname) validate_hostname "$value" ;;
        ssh_port) validate_port "$value" ;;
        kernel_meta) [[ $value == linux-image-amd64 || $value == linux-image-cloud-amd64 ]] ;;
        target_kernel) [[ $value == - || $value =~ ^6\.12\.[0-9]+[a-zA-Z0-9.+~-]*-amd64$ ]] ;;
        ntp_unit) [[ $value == - || $value == systemd-timesyncd.service || $value == chrony.service || $value == ntpsec.service || $value == ntp.service || $value == openntpd.service ]] ;;
        ntp_status) [[ $value == pending || $value == synchronized || $value == unsynchronized || $value == unavailable ]] ;;
        balloon) [[ $value == pending || $value == module || $value == absent ]] ;;
        swap_policy) [[ $value == disk || $value == preserve || $value == skip-space || $value == skip-filesystem || $value == skip || $value == disk1g ]] ;;
        swap_bytes) [[ $value =~ ^[1-9][0-9]{0,18}$ ]] ;;
        mem_kib) [[ $value =~ ^[1-9][0-9]{0,14}$ ]] ;;
        swap_uuid) [[ $value == - ]] || validate_boot_id "$value" ;;
        swap_identity)
            # Keep older completed receipts readable. New tasks record a
            # filesystem UUID instead of a boot-dependent device number.
            [[ $value == - || $value =~ ^[0-9]+:[0-9]+$ ]] ||
                { [[ ${value##*:} =~ ^[1-9][0-9]*$ ]] && validate_boot_id "${value%:*}"; } ;;
        swap_status) [[ $value == pending || $value == building || $value == prepared || $value == active || $value == verified || $value == preserved || $value == skipped ]] ;;
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
    if [[ ${S[format]:-4} == 4 ]]; then printf '%s\n' swap_bytes; fi
}
validate_swap_state() {
    local target expected mem_kib=${S[mem_kib]}
    if [[ ${S[format]} == 3 ]]; then
        # Older completed receipts may be read, but never used to resume a job.
        [[ ${S[phase]} == done && ${S[result_status]} == complete ]] || return 1
        if (( mem_kib <= KIB_PER_GIB )); then
            [[ ${S[swap_policy]} == disk1g && ${S[swap_status]} == verified && ${S[swap_uuid]} != - && ${S[swap_identity]} != - ]]
        else
            [[ ${S[swap_policy]} == skip && ${S[swap_status]} == skipped && ${S[swap_uuid]} == - && ${S[swap_identity]} == - ]]
        fi
        return
    fi
    target=$(swap_target_bytes "${S[mem_kib]}") && [[ ${S[swap_bytes]} == "$target" ]] || return 1
    case ${S[swap_policy]} in
        disk)
            case ${S[swap_status]} in
                pending) [[ ${S[swap_uuid]} == - && ${S[swap_identity]} == - ]] || return 1 ;;
                building) validate_boot_id "${S[swap_uuid]}" || return 1 ;;
                prepared|active|verified) validate_boot_id "${S[swap_uuid]}" && [[ ${S[swap_identity]} != - ]] || return 1 ;;
                *) return 1 ;;
            esac
            if [[ ${S[swap_identity]} != - ]]; then validate_boot_id "${S[swap_identity]%:*}" || return 1; fi
            if [[ ${S[phase]} == swap ]]; then [[ ${S[swap_status]} != verified ]]
            elif [[ ${S[result_status]} == running ]]; then [[ ${S[swap_status]} == active ]]
            else [[ ${S[swap_status]} == verified ]]; fi ;;
        preserve|skip-space|skip-filesystem)
            [[ ${S[swap_uuid]} == - && ${S[swap_identity]} == - ]] || return 1
            expected=preserved
            if [[ ${S[swap_policy]} != preserve ]]; then
                (( mem_kib > KIB_PER_GIB )) || return 1
                expected=skipped
            fi
            if [[ ${S[phase]} == swap ]]; then expected=pending; fi
            [[ ${S[swap_status]} == "$expected" ]] ;;
        *) return 1 ;;
    esac
}
validate_state() {
    local key count=0
    while IFS= read -r key; do
        [[ -v S[$key] ]] && validate_state_value "$key" "${S[$key]}" || return 1
        count=$((count+1))
    done < <(state_keys)
    (( ${#S[@]} == count )) || return 1
    [[ ${S[ntp_status]} != synchronized || ${S[ntp_unit]} != - ]] || return 1
    [[ ${S[result_status]} == running || ${S[ntp_status]} != pending ]] || return 1
    validate_swap_state || return 1
    if [[ ${S[reboot_wait]} != none ]]; then
        validate_boot_id "${S[boot_before]}" && [[ ${S[reboot_count]} != 0 && ${S[target_kernel]} != - ]] || return 1
    fi
    [[ ${S[phase]} == swap || ${S[phase]} == update || ${S[target_kernel]} != - ]] || return 1
    [[ ${S[target_kernel]} == - || $(kernel_meta_for_abi "${S[target_kernel]}") == "${S[kernel_meta]}" ]] || return 1
    [[ ${S[reboot_wait]} == none || ${S[reboot_wait]} == "${S[phase]}" ]] || return 1
    case ${S[result_status]} in
        complete) [[ ${S[phase]} == "done" && ${S[failed]} == no ]] || return 1 ;;
        cleanup_pending) [[ ${S[phase]} == cleanup ]] || return 1 ;;
        running) [[ ${S[phase]} != cleanup && ${S[phase]} != "done" ]] || return 1 ;;
    esac
    if [[ ${S[result_status]} != running ]]; then
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
state_stage_file_ok() {
    plain_root_file "$1" && [[ $(stat -c %a -- "$1") == 600 && $(stat -c %h -- "$1") == 1 ]]
}
discard_interrupted_state_write() {
    local stage=$BASE/.state-pending
    [[ -e $stage || -L $stage ]] || return 0
    bootstrap_dir_ok && plain_root_file "$BASE/owner" && [[ $(cat "$BASE/owner") == "${S[task_id]}" ]] &&
        state_stage_file_ok "$stage" || die 'Unsafe interrupted state write; it was not removed.'
    rm -- "$stage"
}
write_state_to() {
    local file=$1 tmp parent=${1%/*}
    validate_state || die 'Internal state validation failed.'
    [[ -d $parent && ! -L $parent ]] || die "Invalid state parent: $parent"
    [[ ! -L $file ]] || die 'State destination is a symlink.'
    if [[ $file == "$STATE_FILE" ]]; then
        # This is a reserved scratch path inside the verified task directory.
        # The previous committed state remains usable after an interrupted write.
        discard_interrupted_state_write || return 1
        tmp=$BASE/.state-pending
        (umask 077; set -o noclobber; : > "$tmp") || return 1
    else
        tmp=$(mktemp "$parent/.next-vps-setup-state.XXXXXX") || return 1
    fi
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
    local expected=$1 configured listeners policy_sha
    /usr/sbin/sshd -t || die 'Invalid SSH configuration.'
    nv_task_require_ssh_boot
    configured=$(/usr/sbin/sshd -T | awk '$1=="port" {print $2}' | sort -u)
    [[ $configured == "$expected" ]] || die 'Expected port and SSH configuration disagree, or multiple ports are configured.'
    listeners=$(ss -H -lntp | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}' | sort -u)
    [[ $listeners == "$expected" ]] || die 'Actual sshd listeners disagree with the selected port.'
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        local _client _client_port _server server_port rest
        read -r _client _client_port _server server_port rest <<< "$SSH_CONNECTION"
        [[ -z ${rest:-} && $server_port == "$expected" ]] || die 'Current SSH connection uses a different server port.'
    fi
    if [[ -v S[ssh_policy_sha] ]]; then
        policy_sha=$(ssh_policy_sha) || die 'Cannot read the effective SSH authentication policy.'
        [[ $policy_sha == "${S[ssh_policy_sha]}" ]] || die 'SSH authentication policy changed; inspect before continuing.'
    fi
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
    local root_free boot_free var_free inodes available root_dev swap_dev needed_root=$((2 * KIB_PER_GIB))
    root_free=$(df -k --output=avail -- / | awk 'NR==2{print $1}') &&
        boot_free=$(df -k --output=avail -- /boot | awk 'NR==2{print $1}') &&
        inodes=$(df --output=iavail -- / | awk 'NR==2{print $1}') &&
        available=$(awk '$1=="MemAvailable:"{print $2}' /proc/meminfo) || die 'Cannot inspect available resources.'
    var_free=$(swap_free_kib) || return 1
    local value
    for value in "$root_free" "$boot_free" "$inodes" "$available"; do
        [[ $value =~ ^(0|[1-9][0-9]{0,14})$ ]] || die 'Cannot inspect available resources.'
    done
    if [[ ${S[swap_status]:-pending} == active || ${S[swap_status]:-pending} == verified ]]; then
        root_dev=$(stat -c %d -- /) && swap_dev=$(stat -c %d -- "$SWAP_FILE") || die 'Cannot inspect the root and Swap filesystems.'
        if [[ $root_dev == "$swap_dev" ]]; then needed_root=$KIB_PER_GIB; fi
    fi
    (( root_free >= needed_root && boot_free >= 204800 && var_free >= SWAP_RESERVE_KIB && inodes >= 10000 && available >= 131072 )) ||
        die 'Insufficient resources: need 2 GiB free on / (1 GiB after creating Swap on the same filesystem), 1 GiB on /var/lib, 200 MiB on /boot, 10000 free root inodes and 128 MiB MemAvailable.'
}
check_os() {
    [[ $(id -u) == 0 ]] || die 'Use a root login, or sudo -i, then run the local /root copy.'
    nv_notice_lock_dir_ok /root || die 'root 主目录须由 root 独占访问，才能安全保存登录通知。'
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
    hostnamectl --static >/dev/null && timedatectl show -p Timezone --value >/dev/null ||
        die '无法读取主机名或时区。请先确认系统 D-Bus、systemd-hostnamed 和 systemd-timedated 可用。'
}
cloud_init_preflight() {
    local status manage
    if command -v cloud-init >/dev/null 2>&1; then
        status=$(cloud-init status --long) || true
        case ${status%%$'\n'*} in
            'status: disabled') return 0 ;;
            'status: done') ;;
            'status: not started'|'status: running')
                die 'cloud-init 尚未完成。请等待镜像初始化结束后再启动本工具。' ;;
            *) die '无法确认 cloud-init 已正常完成。请先查看 cloud-init status --long。' ;;
        esac
        manage=$(cloud-init query combined_cloud_config.manage_etc_hosts 2>/dev/null) ||
            manage=$(cloud-init query merged_system_cfg.manage_etc_hosts 2>/dev/null) ||
            manage=$(cloud-init query merged_cfg.manage_etc_hosts 2>/dev/null) || manage=
        if [[ ${manage,,} =~ ^[[:space:]]*(true|1|on|yes|template)[[:space:]]*$ ]]; then
            die '此镜像由 cloud-init 在开机时重写 /etc/hosts。请先确认主机名及 hosts 的持久配置方式。'
        fi
    fi
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
    mode=$(stat -c %a -- "$1") && uid=$(stat -c %u -- "$1") || return 1
    apt_uid=$(id -u _apt) || return 1
    [[ $uid == 0 || ( ${2:-root} == download && $uid == "$apt_uid" ) ]] || return 1
    if [[ ${2:-root} == download ]]; then [[ $mode == 755 || $mode == 700 ]]; else [[ $mode == 755 ]]; fi
}
official_apt_sandbox_test() {
    local uid gid
    uid=$(id -u _apt) && [[ $uid =~ ^[1-9][0-9]*$ ]] || return 1
    gid=$(id -g _apt) && [[ $gid =~ ^[0-9]+$ ]] || return 1
    setpriv --reuid="$uid" --regid="$gid" --clear-groups --inh-caps=-all -- /usr/bin/test "$@"
}
official_apt_keyring_target() {
    local keyring=/usr/share/keyrings/debian-archive-keyring.gpg target link
    target=$keyring
    official_apt_dir_ok "${keyring%/*}" || return 1
    if [[ -L $keyring ]]; then
        # Debian 13 ships this one compatibility link. Other APT files remain
        # subject to the no-symlink rule in official_apt_file_ok.
        [[ $(stat -c %u -- "$keyring") == 0 ]] || return 1
        link=$(readlink -n -- "$keyring" && printf '.') || return 1
        link=${link%.}
        case $link in
            debian-archive-keyring.pgp|/usr/share/keyrings/debian-archive-keyring.pgp)
                target=/usr/share/keyrings/debian-archive-keyring.pgp ;;
            *) return 1 ;;
        esac
    fi
    official_apt_file_ok "$target" && [[ -s $target && -r $target && $(readlink -e -- "$target") == "$target" ]] || return 1
    printf '%s\n' "$target"
}
check_sources() {
    local keyring root mode sandbox_uid
    # Host source files, pins and APT hooks are neither loaded nor changed.
    command -v setpriv >/dev/null || die '系统缺少 setpriv，无法核验 APT 下载沙箱。'
    sandbox_uid=$(id -u _apt) && [[ $sandbox_uid =~ ^[1-9][0-9]*$ ]] || die '系统缺少有效的 APT 下载沙箱用户。'
    keyring=$(official_apt_keyring_target) || die 'Debian 官方密钥文件缺失、权限异常或链接目标不受支持，请保留 ls -l /usr/share/keyrings/debian-archive-keyring.* 的输出供排查。'
    mode=$(stat -c %a -- "$keyring") || die '无法读取 Debian 签名密钥权限。'
    (( (8#$mode & 004) != 0 )) && official_apt_sandbox_test -r "$keyring" || die 'APT 下载沙箱无法读取 Debian 签名密钥，请检查用户和路径权限。'
    [[ $BASE =~ ^/[a-zA-Z0-9_./-]+$ ]] || die 'Unsafe private APT path.'
    root=$(official_apt_root) || return 1
    official_apt_dir_ok "${root%/*}" && official_apt_sandbox_test -x "${root%/*}" ||
        die 'APT 下载沙箱无法访问暂存目录的父路径，请检查 /var/lib 及上级目录权限。'
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
Dir::Cache "$root";
Dir::Cache::archives "$root/archives";
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
official_apt_stage_path() { printf '%s/.%s.pending-%s\n' "${1%/*}" "${1##*/}" "${S[task_id]}"; }
official_apt_publish() {
    local path=$1 content=$2 tmp mode bytes
    tmp=$(official_apt_stage_path "$path") || return 1
    if [[ -e $tmp || -L $tmp ]]; then
        official_apt_file_ok "$tmp" || die '更新暂存文件的归属或类型不安全，已保留现场。'
        mode=$(stat -c %a -- "$tmp") && bytes=$(stat -c %s -- "$tmp") || return 1
        [[ $mode == 600 || $mode == 644 ]] && [[ $bytes =~ ^[0-9]+$ ]] &&
            cmp -s -n "$bytes" -- "$tmp" <(printf '%s' "$content") || die '更新暂存文件与本任务配置不匹配，已保留现场。'
    fi
    if [[ -e $path || -L $path ]]; then
        official_apt_file_ok "$path" && cmp -s "$path" <(printf '%s' "$content") || die '本次更新使用的官方源配置已被改动，已停止以避免使用未知配置。'
        if [[ -e $tmp ]]; then rm -- "$tmp" && sync -f "${path%/*}" || return 1; fi
        return 0
    fi
    if [[ ! -e $tmp ]]; then (umask 077; set -o noclobber; : > "$tmp") || return 1; fi
    printf '%s' "$content" > "$tmp" && chmod 0644 "$tmp" && sync -f "$tmp" || return 1
    mv -T --no-copy --update=none-fail -- "$tmp" "$path" || return 1
    sync -f "${path%/*}"
}
official_apt_index_name_ok() {
    [[ $1 =~ ^(deb\.debian\.org_debian_dists_trixie(-updates)?|security\.debian\.org_debian-security_dists_trixie-security)_[a-zA-Z0-9_.%+~-]+$ ]]
}

official_apt_archive_name_ok() {
    local suffix='[.]deb'
    [[ ${2:-final} != partial ]] || suffix+='([.]FAILED)?'
    [[ $1 =~ ^[a-z0-9][a-z0-9.+-]*_[a-zA-Z0-9.+:%~-]+_(all|amd64)$suffix$ ]]
}

official_apt_download_file_ok() {
    local uid mode apt_uid
    [[ -f $1 && ! -L $1 && $(stat -c %h -- "$1") == 1 ]] || return 1
    uid=$(stat -c %u -- "$1"); mode=$(stat -c %a -- "$1"); apt_uid=$(id -u _apt) || return 1
    [[ $uid == 0 || $uid == "$apt_uid" ]] || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 022) == 0 ))
}

official_apt_collect_paths() {
    local root=$1 fd producer failed=no
    local -n collected=$2
    # Wait for find explicitly: process-substitution failures do not otherwise
    # propagate through mapfile/while. Keep names NUL-delimited throughout.
    exec {fd}< <(find -P "$root" -xdev -mindepth 1 -print0) || return 1
    producer=$!
    mapfile -d '' -t collected <&"$fd" || failed=yes
    exec {fd}<&- || failed=yes
    wait "$producer" || failed=yes
    [[ $failed == no ]]
}

official_apt_partial_link_ok() {
    local path=$1 root name target link
    root=$(official_apt_root)
    [[ $path == "$root/lists/partial/"* && -L $path && $(stat -c %u -- "$path") == 0 && $(stat -c %h -- "$path") == 1 ]] || return 1
    name=${path#"$root/lists/partial/"}
    official_apt_index_name_ok "$name" || return 1
    target=$root/lists/$name
    # APT's root controller creates this direct IMS-hit alias. No other
    # symlink, link chain, or path outside this task's final list is accepted.
    link=$(readlink -n -- "$path" && printf '.') || return 1
    link=${link%.}
    [[ $link == "$target" || $link == "../$name" ]] || return 1
    official_apt_file_ok "$target" || return 1
}

official_apt_clear_partial_links() {
    local root path
    root=$(official_apt_root)
    for path in "$root/lists/partial"/* "$root/lists/partial"/.[!.]* "$root/lists/partial"/..?*; do
        [[ -L $path ]] || continue
        official_apt_partial_link_ok "$path" || return 1
        rm -- "$path" || return 1
    done
}

official_apt_check_tree() {
    local root path relative name
    local -a scanned_paths=()
    root=$(official_apt_root)
    official_apt_dir_ok "$root" || return 1
    official_apt_collect_paths "$root" scanned_paths || return 1
    for path in "${scanned_paths[@]}"; do
        relative=${path#"$root"/}
        case $relative in
            owner|apt.conf|empty.conf|official.sources|preferences|auth.conf)
                official_apt_file_ok "$path" || return 1 ;;
            parts|sourceparts|preferencesparts|trustedparts|authparts|lists|archives)
                official_apt_dir_ok "$path" || return 1 ;;
            lists/partial|lists/auxfiles|archives/partial)
                official_apt_dir_ok "$path" download || return 1 ;;
            lists/*)
                name=${relative##*/}
                [[ $name == lock ]] || official_apt_index_name_ok "$name" || return 1
                case $relative in
                    lists/partial/*|lists/auxfiles/*)
                        [[ $relative == "lists/partial/$name" || $relative == "lists/auxfiles/$name" ]] || return 1
                        if [[ -L $path ]]; then official_apt_partial_link_ok "$path" || return 1
                        else
                            official_apt_download_file_ok "$path" || return 1
                        fi ;;
                    *)
                        [[ $relative == "lists/$name" ]] || return 1
                        official_apt_file_ok "$path" || return 1 ;;
                esac ;;
            archives/*)
                name=${relative##*/}
                case $relative in
                    archives/partial/*)
                        [[ $relative == "archives/partial/$name" ]] || return 1
                        [[ $name == lock ]] || official_apt_archive_name_ok "$name" partial || return 1
                        official_apt_download_file_ok "$path" || return 1 ;;
                    *)
                        [[ $relative == "archives/$name" ]] || return 1
                        [[ $name == lock ]] || official_apt_archive_name_ok "$name" || return 1
                        official_apt_file_ok "$path" || return 1 ;;
                esac ;;
            *) return 1 ;;
        esac
    done
    if (( $# )); then
        local -n validated_paths=$1
        validated_paths=("${scanned_paths[@]}")
    fi
}
official_apt_prepare() {
    local root directory content path mode access apt_uid owner owner_stage
    local -a entries=()
    check_sources || return 1
    root=$(official_apt_root) || return 1
    [[ -n ${S[task_id]:-} && ${S[task_id]} =~ ^[a-f0-9-]{36}$ ]] || die 'A task identity is required for private APT.'
    if [[ ! -e $root && ! -L $root ]]; then mkdir -m 0755 -- "$root" || die '无法创建更新暂存目录。'; fi
    official_apt_dir_ok "$root" || die '更新暂存目录的权限或类型不安全，已停止。'
    if [[ ! -e $root/owner && ! -L $root/owner ]]; then
        owner_stage=$(official_apt_stage_path "$root/owner") || return 1
        official_apt_collect_paths "$root" entries || die '无法检查更新暂存目录。'
        if [[ -n ${entries[0]:-} ]]; then
            [[ ${#entries[@]} == 1 && ${entries[0]} == "$owner_stage" ]] || die '更新暂存目录含有无法确认归属的内容。'
        fi
    fi
    official_apt_publish "$root/owner" "${S[task_id]}"$'\n' || die '无法保存更新暂存目录归属。'
    for directory in parts sourceparts preferencesparts trustedparts authparts lists lists/partial lists/auxfiles archives archives/partial; do
        path=$root/$directory
        mode=0755
        access=root
        [[ $directory != */partial ]] || mode=0700
        case $directory in lists/partial|lists/auxfiles|archives/partial) access=download ;; esac
        if [[ ! -e $path && ! -L $path ]]; then mkdir -m "$mode" -- "$path" || die "无法创建 APT 暂存子目录：$path"; fi
        official_apt_dir_ok "$path" "$access" || die "APT 暂存子目录的权限或类型不安全：$path"
    done
    official_apt_publish "$root/empty.conf" '' || die '无法保存 APT 暂存主配置。'
    official_apt_publish "$root/preferences" '' || die '无法保存 APT 暂存优先级配置。'
    official_apt_publish "$root/auth.conf" '' || die '无法保存 APT 暂存认证配置。'
    content=$(official_apt_sources_content) && official_apt_publish "$root/official.sources" "$content"$'\n' ||
        die '无法保存本次更新的官方源。'
    content=$(official_apt_config_content) && official_apt_publish "$root/apt.conf" "$content"$'\n' ||
        die '无法保存本次更新的 APT 配置。'
    official_apt_check_tree || die '更新暂存目录出现未知内容或权限变化，已停止，请保留现场检查。'
    apt_uid=$(id -u _apt) && [[ $apt_uid =~ ^[1-9][0-9]*$ ]] || die '系统缺少有效的 APT 下载沙箱用户。'
    for directory in lists/partial lists/auxfiles archives/partial; do
        path=$root/$directory
        owner=$(stat -c %u -- "$path") || die "无法读取 APT 下载目录归属：$path"
        # APT uses _apt:root for its downloads. Check access before APT can
        # silently fall back to downloading as root.
        if [[ $owner == 0 ]]; then chown --no-dereference "$apt_uid:0" -- "$path" || die "无法设置 APT 下载目录归属：$path"; fi
        official_apt_sandbox_test -x "$path" && official_apt_sandbox_test -w "$path" ||
            die "APT 下载沙箱无法写入暂存目录：$path"
    done
    official_apt_clear_partial_links || die '无法安全清理本次官方索引的中断链接，请保留现场检查。'
}
official_apt_exec() {
    local tool=$1 root; shift
    root=$(official_apt_root) || return 1
    official_apt_file_ok "$root/apt.conf" && cmp -s "$root/apt.conf" <(official_apt_config_content) ||
        die '本次更新的 APT 配置缺失或已改变，已停止。'
    env -u APT_CONFIG -u DPKG_ROOT -u DPKG_ADMINDIR -u DPKG_FORCE -u DPKG_FRONTEND_LOCKED \
        -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        APT_CONFIG="$root/apt.conf" DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 NEEDRESTART_MODE=l \
        "$tool" "$@"
}
apt_run() { official_apt_prepare && official_apt_exec apt-get "$@"; }
apt_cache() { official_apt_prepare && official_apt_exec apt-cache "$@"; }
official_apt_empty_packages() {
    # APT omits Packages when the authenticated InRelease declares it empty.
    # This is a readiness check only; signature verification remains with APT.
    awk '
        $0=="SHA256:" {in_sha=1; next}
        /^[^[:space:]]/ {in_sha=0}
        in_sha && NF==3 && $3=="main/binary-amd64/Packages" {
            count++
            if($1=="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" && $2=="0") empty++
        }
        END {exit !(count==1 && empty==1)}' "$1"
}
official_apt_ready() {
    local root prefix file found
    root=$(official_apt_root)
    for prefix in deb.debian.org_debian_dists_trixie deb.debian.org_debian_dists_trixie-updates security.debian.org_debian-security_dists_trixie-security; do
        [[ -s $root/lists/${prefix}_InRelease ]] || return 1
        found=no
        for file in "$root/lists/${prefix}_main_binary-amd64_Packages" "$root/lists/${prefix}_main_binary-amd64_Packages."*; do
            [[ ! -s $file ]] || found=yes
        done
        if [[ $found != yes ]]; then
            official_apt_empty_packages "$root/lists/${prefix}_InRelease" || return 1
        fi
    done
}
check_origins() {
    local output; output=$(apt_cache policy) || die '无法读取本次更新的软件源来源。'
    awk '/^[[:space:]]*release / {
        if($0~/a=now([,[:space:]]|$)/)next
        if($0!~/o=Debian(-Security)?([,[:space:]]|$)/ || $0!~/n=trixie(-updates|-security)?([,[:space:]]|$)/)bad=1
        n++
    } END{exit(bad||n==0)}' <<< "$output" || die '软件索引未通过 Debian 13 官方来源检查，已停止。'
}
strict_update() { apt_run --error-on=any update && check_origins; }
official_apt_cleanup() {
    local root retired path
    local -a paths=()
    root=$(official_apt_root) || return 1
    [[ ${S[task_id]:-} =~ ^[a-f0-9-]{36}$ ]] || die '缺少可核验的任务编号，未执行更新暂存目录清理。'
    retired=$root.cleanup-${S[task_id]}
    [[ -e $root || -L $root || -e $retired || -L $retired ]] || return 0
    official_apt_dir_ok "${root%/*}" || die '更新暂存目录父路径不安全，未执行清理。'
    if [[ -e $root || -L $root ]]; then
        [[ ! -e $retired && ! -L $retired ]] || die '发现两个更新暂存目录，未执行清理。'
        official_apt_dir_ok "$root" && official_apt_file_ok "$root/owner" || die '更新暂存目录或归属记录不安全，未执行清理。'
        cmp -s "$root/owner" <(printf '%s\n' "${S[task_id]}") || die '更新暂存目录不属于本次任务，未执行清理。'
        official_apt_check_tree paths || die '更新暂存目录含有未知内容，未执行清理，请保留现场检查。'
        official_apt_clear_partial_links || die '本次官方索引的中断链接未能安全清理，未继续删除。'
        # Reuse the checked paths. Download users may write to partial
        # directories but cannot replace the root-controlled parents.
        for path in "${paths[@]}"; do
            [[ ! -f $path || -L $path || $path == "$root/owner" ]] || rm -- "$path" || return 1
        done
        for path in lists/partial lists/auxfiles lists archives/partial archives parts sourceparts preferencesparts trustedparts authparts; do
            [[ ! -d $root/$path ]] || rmdir -- "$root/$path" || return 1
        done
        # Keep the owner until the verified directory is retired under this
        # task ID. After that rename, an empty retired directory is resumable.
        mv -T --no-copy --update=none-fail -- "$root" "$retired" || return 1
        sync -f "${root%/*}" || return 1
    fi
    official_apt_dir_ok "$retired" && official_apt_collect_paths "$retired" paths || die '待移除的更新暂存目录不安全，未执行清理。'
    if [[ -n ${paths[0]:-} ]]; then
        [[ ${#paths[@]} == 1 && ${paths[0]} == "$retired/owner" ]] && official_apt_file_ok "$retired/owner" ||
            die '待移除的更新暂存目录包含未知内容，未执行清理。'
        cmp -s "$retired/owner" <(printf '%s\n' "${S[task_id]}") || die '待移除的更新暂存目录不属于本次任务。'
        rm -- "$retired/owner" || return 1
    fi
    rmdir -- "$retired" || return 1
    sync -f "${root%/*}"
}
# END NEXT-VPS OFFICIAL APT VIEW
# BEGIN EMBEDDED kernel-identity
# Confirm the running amd64 build, including upgrades that reuse an ABI name.
# File trust/ownership is checked by the caller before this read-only helper.
nv_kernel_image_matches() {
    /usr/bin/python3 -I - "$1" "$2" "$3" <<'NEXT_VPS_KERNEL_IDENTITY'
import os
import stat
import struct
import sys

def check(path, release, version):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o022:
            raise ValueError("unsafe kernel image type or permissions")
        with os.fdopen(fd, "rb", closefd=False) as image:
            header = image.read(0x210)
            if (len(header) != 0x210 or header[0x1fe:0x200] != b"\x55\xaa"
                    or header[0x202:0x206] != b"HdrS"
                    or struct.unpack_from("<H", header, 0x206)[0] < 0x200):
                raise ValueError("unsupported x86 boot header")
            setup_end = ((header[0x1f1] or 4) + 1) * 512
            offset = 0x200 + struct.unpack_from("<H", header, 0x20e)[0]
            if not 0x210 <= offset < min(setup_end, metadata.st_size):
                raise ValueError("invalid kernel version pointer")
            image.seek(offset)
            raw = image.read(min(512, setup_end - offset, metadata.st_size - offset))
            if b"\0" not in raw:
                raise ValueError("unterminated kernel version")
            banner = raw.split(b"\0", 1)[0]
            if not banner or any(byte < 32 or byte > 126 for byte in banner):
                raise ValueError("invalid kernel version text")
            banner = banner.decode("ascii")
            if not (banner.startswith(release + " (") and banner.endswith(") " + version)):
                raise ValueError("running kernel build differs from the target boot image")
    finally:
        os.close(fd)

try:
    check(*sys.argv[1:])
except (OSError, ValueError, struct.error) as error:
    print("KERNEL_IDENTITY_ERROR: " + str(error), file=sys.stderr)
    raise SystemExit(1)
NEXT_VPS_KERNEL_IDENTITY
}
# END EMBEDDED kernel-identity

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
    [[ $(kernel_meta_for_abi "${S[target_kernel]}") == "${S[kernel_meta]}" ]] || die 'Kernel metapackage would change the original kernel flavour.'
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
    printf 'format\t1\ntask_id\t%s\nmachine_id\t%s\nswap_uuid\t%s\nbytes\t%s\n' "${S[task_id]}" "${S[machine_id]}" "${S[swap_uuid]}" "${S[swap_bytes]}"
}
swap_unit_content() {
    local bytes=${S[swap_bytes]}
    printf '%s\n' '# Managed by next-vps-setup' '[Unit]' "Description=next-vps-setup disk Swap ($((bytes / BYTES_PER_GIB)) GiB)" \
        '' '[Swap]' "What=$SWAP_FILE" 'Priority=10' 'TimeoutSec=90s' \
        '' '[Install]' 'WantedBy=swap.target'
}
swap_sysctl_content() { printf '%s\n' '# Managed by next-vps-setup' 'vm.swappiness = 10'; }
swap_mount_field() {
    local value
    value=$(findmnt --raw --noheadings --first-only --nofsroot --output "$1" --target /var/lib) || die '无法读取 /var/lib 的文件系统信息。'
    [[ -n $value && $value != *[[:space:]]* ]] || die 'Ambiguous Swap filesystem metadata.'
    printf '%s\n' "$value"
}
swap_require_writable_varlib() {
    local options
    options=$(swap_mount_field OPTIONS) || return 1
    [[ ,$options, == *,rw,* && ,$options, != *,ro,* ]] || die '/var/lib 不可写，无法保存任务状态及 APT 暂存文件。'
}
swap_ext4_device_check() {
    local source uuid
    source=$(swap_mount_field SOURCE) || return 1
    [[ $source == /dev/* && -b $source ]] || die '无法确认 /var/lib 对应的本地 ext4 块设备。'
    uuid=$(swap_mount_field UUID) && validate_boot_id "$uuid" || die 'The Swap filesystem must have a readable ext4 UUID.'
}
swap_filesystem_check() {
    local type
    swap_require_writable_varlib || return 1
    type=$(swap_mount_field FSTYPE) || return 1
    [[ $type == ext4 ]] || die '本任务的 Swap 必须位于可写的本地 ext4 文件系统。'
    swap_ext4_device_check
}
swap_file_identity() {
    local file=$1 uuid inode
    uuid=$(swap_mount_field UUID) && validate_boot_id "$uuid" || return 1
    inode=$(stat -c %i -- "$file") && [[ $inode =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s:%s\n' "$uuid" "$inode"
}
swap_rows() {
    awk '
        NR==1 {if(NF!=5 || $1!="Filename" || $2!="Type" || $3!="Size" || $4!="Used" || $5!="Priority")bad=1; next}
        NF!=5 || $1!~/^\// || ($2!="file" && $2!="partition") || $3!~/^[1-9][0-9]*$/ ||
        $4!~/^[0-9]+$/ || $5!~/^-?[0-9]+$/ {bad=1; next}
        {printf "%s\t%s\t%s\t%s\n",$1,$2,$3,$5}
        END{if(!NR || bad)exit 1}' /proc/swaps
}
swap_inventory() {
    local mode=$1 rows fstab listing unit rest result=none
    rows=$(swap_rows) || die '无法完整读取活动 Swap。'
    if [[ -n $rows ]]; then
        if [[ $mode == owned ]]; then
            [[ $rows != *$'\n'* && $rows == "$SWAP_FILE"$'\tfile\t'* ]] || die '发现其他活动 Swap，未停用或替换。'
        fi
        result=active
    fi
    if [[ -e /etc/fstab || -L /etc/fstab ]]; then
        [[ -f /etc/fstab && -r /etc/fstab ]] || die '无法读取 /etc/fstab 的 Swap 配置。'
        fstab=$(awk '$1!~/^#/ && $3=="swap" {found=1} END{print found?"yes":"no"}' /etc/fstab) ||
            die '无法检查 /etc/fstab 的 Swap 配置。'
        if [[ $fstab == yes ]]; then
            [[ $mode == new ]] || die '发现已有 fstab Swap，未修改其配置。'
            if [[ $result == none ]]; then result=configured; fi
        fi
    fi
    # list-unit-files without a type filter also works on a system with no Swap.
    listing=$(systemctl list-unit-files --full --no-legend --no-pager &&
        systemctl list-units --all --type=swap --plain --full --no-legend --no-pager) || die '无法读取 systemd 的 Swap 单元。'
    while read -r unit rest; do
        [[ $unit == *.swap ]] || continue
        if [[ $mode == owned ]]; then
            [[ $unit == "$SWAP_UNIT" ]] || die "发现其他 Swap 单元：$unit"
        else
            [[ $unit != "$SWAP_UNIT" ]] || die "已有单元占用了本工具的 Swap 名称：$unit"
            if [[ $result == none ]]; then result=configured; fi
        fi
    done <<< "$listing"
    printf '%s\n' "$result"
}
swap_check_tuning_conflicts() {
    local mode=$1 file value status
    if [[ -e /sys/module/zswap/parameters/enabled ]]; then
        value=$(cat /sys/module/zswap/parameters/enabled) || die '无法读取 zswap 状态。'
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
    local file directory_device parent_device
    safe_swap_dir "$SWAP_DIR" && [[ $(stat -c %a -- "$SWAP_DIR") == 700 ]] || die 'Unsafe persistent Swap directory.'
    directory_device=$(stat -c %d -- "$SWAP_DIR") && parent_device=$(stat -c %d -- /var/lib) ||
        die 'Cannot identify the persistent Swap directory filesystem.'
    [[ $directory_device == "$parent_device" ]] || die 'Persistent Swap directory is mounted on a separate filesystem.'
    plain_root_file "$SWAP_OWNER" && [[ $(stat -c %h -- "$SWAP_OWNER") == 1 && $(stat -c %a -- "$SWAP_OWNER") == 644 ]] &&
        cmp -s "$SWAP_OWNER" <(swap_owner_content) || die 'Disk Swap ownership record differs; no file was adopted.'
    for file in "$SWAP_DIR"/* "$SWAP_DIR"/.[!.]* "$SWAP_DIR"/..?*; do
        [[ -e $file || -L $file ]] || continue
        case $file in "$SWAP_OWNER"|"$SWAP_FILE") plain_root_file "$file" || die 'Unsafe owned Swap file.' ;; *) die "Unknown persistent Swap directory entry: $file" ;; esac
    done
}
swap_check_paths() {
    local mode=$1 file directory
    safe_swap_dir /var/lib && safe_swap_dir /etc/systemd/system && safe_swap_dir /etc/sysctl.d ||
        die 'Swap 配置目录的归属或路径不安全。'
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
}
swap_free_kib() {
    local free
    free=$(df -k --output=avail -- /var/lib | awk 'NR==2{print $1}') || die '无法读取 /var/lib 的剩余磁盘空间。'
    [[ $free =~ ^(0|[1-9][0-9]{0,14})$ ]] || die '/var/lib 的剩余磁盘空间读数异常。'
    printf '%s\n' "$free"
}
swap_usable_kib() {
    local bytes=$1 page
    page=$(getconf PAGESIZE) || die '无法读取系统页大小。'
    [[ $page =~ ^[1-9][0-9]{3,5}$ ]] &&
        (( page % 1024 == 0 && (page & (page - 1)) == 0 && bytes % page == 0 &&
           bytes / page >= 10 && bytes / page <= SWAP_MAX_PAGES )) ||
        die '目标容量超出单个 Swap 文件支持的页数，未开始分配。'
    printf '%s\n' "$(((bytes - page) / 1024))"
}
swap_plan() {
    local memory=$1 bytes=$2 existing type free need
    swap_check_paths new || return 1
    swap_require_writable_varlib || return 1
    existing=$(swap_inventory new) || return 1
    if [[ $existing != none ]]; then
        [[ $existing == active ]] || (( memory > KIB_PER_GIB )) ||
            die '系统已有 Swap 配置，但当前没有活动 Swap。低内存机器请先确认该配置并启用后重试。'
        printf 'preserve\n'
        return
    fi
    swap_check_tuning_conflicts new || return 1
    swap_usable_kib "$bytes" >/dev/null || return 1
    type=$(swap_mount_field FSTYPE) || return 1
    if [[ $type != ext4 ]]; then
        (( memory > KIB_PER_GIB )) || die "低内存机器需要可写的本地 ext4 文件系统创建 Swap，当前 /var/lib 为 $type。"
        printf 'skip-filesystem\n'
        return
    fi
    swap_ext4_device_check || return 1
    free=$(swap_free_kib) || return 1
    # Leave a small allowance for task files and filesystem allocation
    # metadata. The actual reserve is checked after writing the file.
    need=$((bytes / 1024 + SWAP_RESERVE_KIB + SWAP_PREPARE_KIB))
    if (( free < need )); then
        (( memory > KIB_PER_GIB )) || die "创建 Swap 并保留余量需要 $need KiB，/var/lib 目前只有 $free KiB 空闲。"
        printf 'skip-space\n'
        return
    fi
    printf 'disk\n'
}
swap_require_owned_file() {
    local current bytes=${S[swap_bytes]}
    plain_root_file "$SWAP_FILE" && [[ ${S[swap_identity]} != - && $(swap_file_identity "$SWAP_FILE") == "${S[swap_identity]}" &&
        $(stat -c %a -- "$SWAP_FILE") == 600 && $(stat -c %h -- "$SWAP_FILE") == 1 ]] ||
        die '本任务的 Swap 文件归属或权限已变化，已保留现场。'
    current=$(stat -c %s -- "$SWAP_FILE") || die '无法读取 Swap 文件大小。'
    [[ $current =~ ^(0|[1-9][0-9]{0,17})$ ]] && (( current <= bytes )) ||
        die '本任务的 Swap 文件大小异常，未覆盖文件。'
}
swap_allocated_kib() {
    local blocks
    blocks=$(stat -c %b -- "$SWAP_FILE") || die '无法读取 Swap 文件已分配的空间。'
    [[ $blocks =~ ^(0|[1-9][0-9]{0,14})$ ]] || die 'Swap 文件已分配空间的读数异常。'
    printf '%s\n' "$((blocks / 2))"
}
swap_verify_file() {
    local allocated bytes=${S[swap_bytes]}
    swap_inspect_owned; swap_require_owned_file
    [[ $(stat -c %s -- "$SWAP_FILE") == "${S[swap_bytes]}" ]] || die 'Swap 文件大小与目标不一致。'
    allocated=$(swap_allocated_kib) || return 1
    (( allocated >= bytes / 1024 )) || die 'Swap 文件分配不完整或含有空洞。'
    [[ $(blkid -p -s TYPE -o value -- "$SWAP_FILE") == swap && $(blkid -p -s UUID -o value -- "$SWAP_FILE") == "${S[swap_uuid]}" ]] ||
        die 'Swap 文件签名与本任务记录不一致。'
}
publish_swap_directory() {
    local stage=$BASE/swap-staged marker file item device parent_device bytes identity
    marker=$stage/owner.tsv; file=$stage/swapfile
    if [[ ! -e $stage && ! -L $stage ]]; then
        [[ ${S[swap_identity]} == - ]] || die 'Recorded Swap staging directory disappeared.'
        mkdir -m 0700 -- "$stage"
    fi
    safe_swap_dir "$stage" && [[ $(stat -c %a -- "$stage") == 700 ]] || die 'Unsafe Swap staging directory.'
    device=$(stat -c %d -- "$stage"); parent_device=$(stat -c %d -- "${SWAP_DIR%/*}")
    [[ $device == "$parent_device" ]] || die 'Swap staging and target must share a filesystem.'
    for item in "$stage"/* "$stage"/.[!.]* "$stage"/..?*; do
        [[ -e $item || -L $item ]] || continue
        case $item in "$marker"|"$file") plain_root_file "$item" || die 'Unsafe staged Swap file.' ;; *) die "Unknown Swap staging entry: $item" ;; esac
        [[ $(stat -c %h -- "$item") == 1 ]] || die 'Unexpected hard link in Swap staging.'
    done
    if [[ ! -f $marker ]] || ! cmp -s -- "$marker" <(swap_owner_content); then
        # Only a prefix of this task's own marker can be an interrupted write.
        [[ ${S[swap_identity]} == - && ! -e $file ]] || die 'Staged Swap ownership record differs.'
        if [[ -f $marker ]]; then
            bytes=$(stat -c %s -- "$marker")
            cmp -s -n "$bytes" -- "$marker" <(swap_owner_content) || die 'Unknown staged Swap ownership record.'
        fi
        swap_owner_content > "$marker"
    fi
    chmod 0644 "$marker"
    if [[ ! -e $file ]]; then
        [[ ${S[swap_identity]} == - ]] || die 'Recorded staged Swap file disappeared.'
        (umask 077; set -o noclobber; : > "$file")
    fi
    [[ $(stat -c %a -- "$file") == 600 && $(stat -c %s -- "$file") == 0 ]] || die 'Unexpected staged Swap file mode or size.'
    identity=$(swap_file_identity "$file") || die 'Cannot identify the staged Swap file.'
    if [[ ${S[swap_identity]} == - ]]; then
        sync -f "$stage"
        S[swap_identity]=$identity; save_state
    else
        [[ $identity == "${S[swap_identity]}" ]] || die 'Recorded staged Swap file identity differs.'
    fi
    # Publish the complete directory only after recording the inode; a restart
    # will see the same inode in either the staging directory or the final one.
    mv -T --no-copy --update=none-fail -- "$stage" "$SWAP_DIR" || die 'Cannot atomically publish the Swap directory without overwriting its destination.'
    sync -f "${SWAP_DIR%/*}"
}
verify_swap_definition() {
    # Verify systemd's fully merged definition, including type-wide and prefix
    # drop-ins, before enabling or starting the unit. No active state is needed.
    local what priority
    nv_task_require_unit_definition "$SWAP_UNIT" "$SWAP_UNIT_FILE"
    what=$(systemctl show "$SWAP_UNIT" -p What --value) && priority=$(systemctl show "$SWAP_UNIT" -p Priority --value) ||
        die '无法读取 systemd 生效的 Swap 路径和优先级。'
    [[ $what == "$SWAP_FILE" && $priority == 10 ]] || die 'Loaded disk Swap unit differs.'
}
verify_live_swap() {
    local rows usable
    systemctl is-active --quiet "$SWAP_UNIT" || die '本任务的 Swap 未启用。'
    rows=$(swap_rows) || die '无法读取 Swap 的活动状态。'
    usable=$(swap_usable_kib "${S[swap_bytes]}") || return 1
    [[ $rows == "$SWAP_FILE"$'\tfile\t'"$usable"$'\t10' ]] || die '已启用 Swap 的路径、可用容量或优先级与预期不一致。'
}
verify_swap() {
    local inventory current
    swap_filesystem_check; swap_check_paths owned; swap_check_tuning_conflicts owned
    inventory=$(swap_inventory owned) && [[ $inventory == active ]] || die '本任务的 Swap 未在活动列表中。'
    swap_verify_file
    plain_root_file "$SWAP_UNIT_FILE" && cmp -s "$SWAP_UNIT_FILE" <(swap_unit_content) || die 'Persistent Swap unit differs.'
    plain_root_file "$SWAP_SYSCTL" && cmp -s "$SWAP_SYSCTL" <(swap_sysctl_content) || die 'Persistent Swap parameter differs.'
    [[ $(systemctl is-enabled "$SWAP_UNIT") == enabled && -L /etc/systemd/system/swap.target.wants/$SWAP_UNIT && $(readlink -e -- /etc/systemd/system/swap.target.wants/"$SWAP_UNIT") == "$SWAP_UNIT_FILE" ]] || die 'Swap is not persistently enabled.'
    verify_swap_definition
    verify_live_swap
    current=$(sysctl -n vm.swappiness) && [[ $current == 10 ]] || die '无法确认当前 swappiness 为 10。'
}
swap_summary() {
    local bytes=${S[swap_bytes]:-$BYTES_PER_GIB} gib
    gib=$((bytes / BYTES_PER_GIB))
    case ${S[swap_policy]} in
        disk|disk1g)
            case ${S[swap_status]} in
                verified) printf '磁盘 Swap：%s GiB，重启核验通过。\n' "$gib" ;;
                active) printf '磁盘 Swap：%s GiB，已启用，等待重启核验。\n' "$gib" ;;
                *) printf '计划创建 %s GiB 磁盘 Swap。预检需 %s GiB 加 %s MiB 空闲，用于保留磁盘余量及保存任务文件。\n' \
                    "$gib" "$((gib + SWAP_RESERVE_KIB / KIB_PER_GIB))" "$((SWAP_PREPARE_KIB / 1024))" ;;
            esac ;;
        preserve) printf 'Swap：保留系统已有的 Swap 配置和参数。\n' ;;
        skip-space) printf 'Swap：/var/lib 空间不足，跳过计划的 %s GiB Swap。\n' "$gib" ;;
        skip-filesystem) printf 'Swap：/var/lib 文件系统不支持自动创建，跳过计划的 %s GiB Swap。\n' "$gib" ;;
        skip) printf 'Swap：已按旧版策略跳过新建。\n' ;;
    esac
}
phase_swap() {
    local plan inventory free allocated need bytes=${S[swap_bytes]}
    if [[ ${S[swap_status]} == pending ]]; then
        # Recheck the decision immediately before the first Swap write. The
        # target size was already committed and does not depend on live RAM.
        plan=$(swap_plan "${S[mem_kib]}" "$bytes") || die 'Swap 预检未通过，尚未创建 Swap。'
        S[swap_policy]=$plan
        note "$(swap_summary)"
        if [[ $plan != disk ]]; then
            if [[ $plan == preserve ]]; then S[swap_status]=preserved; else S[swap_status]=skipped; fi
            S[phase]=update; save_state
            return 0
        fi
        S[swap_uuid]=$(cat /proc/sys/kernel/random/uuid) || die '无法生成 Swap 标识。'
        S[swap_status]=building; save_state
    fi
    if [[ ${S[swap_status]} != active ]]; then
        swap_filesystem_check; swap_check_paths owned; swap_check_tuning_conflicts owned
        swap_usable_kib "$bytes" >/dev/null
        if [[ ${S[swap_status]} == building ]]; then
            if [[ ! -e $SWAP_DIR && ! -L $SWAP_DIR ]]; then
                publish_swap_directory
            else
                [[ ! -e $BASE/swap-staged && ! -L $BASE/swap-staged ]] || die 'Both staged and final Swap directories exist.'
            fi
            swap_require_owned_file
            free=$(swap_free_kib); allocated=$(swap_allocated_kib)
            need=$((bytes / 1024))
            if (( allocated > need )); then allocated=$need; fi
            (( free >= need - allocated + SWAP_RESERVE_KIB )) || die '磁盘空间已不足，保留本任务的 Swap 文件以便恢复。'
            inventory=$(swap_inventory owned) && [[ $inventory == none ]] || die '已有活动或冲突 Swap，未写入 Swap 文件。'
            dd if=/dev/zero of="$SWAP_FILE" bs=1048576 count="$((bytes / 1048576))" conv=fsync status=progress
            mkswap -U "${S[swap_uuid]}" -- "$SWAP_FILE"
            sync -f "$SWAP_FILE"
            swap_verify_file
            S[swap_status]=prepared; save_state
        fi
        # A verified prepared file can be reused even if power was lost
        # before making the unit persistent. It must never be rewritten here.
        swap_verify_file
        free=$(swap_free_kib)
        (( free >= SWAP_RESERVE_KIB )) || die 'Swap 已分配，但磁盘余量不足 1 GiB；请释放空间后恢复。'
        swap_inventory owned >/dev/null
        publish_config "$SWAP_UNIT_FILE" "$(swap_unit_content)"
        systemctl daemon-reload
        verify_swap_definition
        systemctl start "$SWAP_UNIT"
        verify_live_swap
        systemctl enable "$SWAP_UNIT"
        publish_config "$SWAP_SYSCTL" "$(swap_sysctl_content)"
        sysctl -w vm.swappiness=10
        S[swap_status]=active; dirty
    fi
    verify_swap
    S[phase]=update; save_state
    note "$(swap_summary)"
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
    local path=$1 content=$2 parent=${1%/*} ancestor tmp bytes
    ancestor=$parent
    while [[ ! -e $ancestor && ! -L $ancestor ]]; do
        ancestor=${ancestor%/*}; [[ -n $ancestor ]] || ancestor=/
    done
    safe_state_parent "$ancestor" || die "Unsafe configuration directory: $ancestor"
    if [[ $ancestor != "$parent" ]]; then mkdir -p -- "$parent"; fi
    safe_state_parent "$parent" && [[ ! -L $path ]] || die "Unsafe configuration path: $path"
    tmp=$parent/.next-vps-setup-config.${S[task_id]}.${path##*/}
    if [[ -e $tmp || -L $tmp ]]; then
        plain_root_file "$tmp" && [[ $(stat -c %h -- "$tmp") == 1 ]] || die "Unsafe staged configuration: $tmp"
        bytes=$(stat -c %s -- "$tmp") || die "Cannot inspect staged configuration: $tmp"
        cmp -s -n "$bytes" -- "$tmp" <(printf '%s\n' "$content") || die "Unknown staged configuration: $tmp"
    fi
    if [[ -e $path ]]; then
        plain_root_file "$path" && cmp -s -- "$path" <(printf '%s\n' "$content") || die "Existing conflicting configuration: $path"
        if [[ -e $tmp ]]; then rm -- "$tmp"; sync -f "$parent"; fi
        return 0
    fi
    if [[ ! -e $tmp ]]; then (umask 077; set -o noclobber; : > "$tmp"); fi
    printf '%s\n' "$content" > "$tmp"; chmod 0644 "$tmp"; sync -f "$tmp"
    mv -T --no-copy --update=none-fail -- "$tmp" "$path" || die "Cannot publish configuration without overwriting its destination: $path"
    sync -f "$parent"
    [[ $path == "$UNIT_FILE" ]] || dirty
}
jail_content() {
    cat <<'JAIL_HEADER'
# Managed by next-vps-setup v1.3
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
balloon_content() { printf '%s\n' '# Managed by next-vps-setup v1.3' 'blacklist virtio_balloon' 'install virtio_balloon /bin/false'; }
configure_hostname() {
    local hosts=/etc/hosts tmp=/etc/.next-vps-setup-hosts.${S[task_id]} bytes before current
    if [[ $(hostnamectl --static) != "${S[hostname]}" ]]; then hostnamectl set-hostname "${S[hostname]}"; dirty; fi
    if [[ -e $tmp || -L $tmp ]]; then
        safe_state_parent /etc && plain_root_file "$hosts" && plain_root_file "$tmp" &&
            [[ $(stat -c %h -- "$tmp") == 1 ]] || die '已有的 hosts 暂存文件无法安全核验。'
        bytes=$(stat -c %s -- "$tmp") || die '无法读取 hosts 暂存文件。'
        cmp -s -n "$bytes" -- "$tmp" <(cat -- "$hosts" && printf '\n127.0.1.1\t%s\n' "${S[hostname]}") ||
            die 'hosts 暂存文件与当前内容冲突，请保留现场检查。'
        rm -- "$tmp"; sync -f /etc
    fi
    if ! getent hosts "${S[hostname]}" >/dev/null; then
        safe_state_parent /etc && plain_root_file "$hosts" || die '无法安全更新本地主机名记录。'
        before=$(file_sha "$hosts") || die '无法读取原有 hosts 文件。'
        (umask 077; set -o noclobber; : > "$tmp") || die '无法创建 hosts 暂存文件。'
        cat -- "$hosts" > "$tmp"
        printf '\n127.0.1.1\t%s\n' "${S[hostname]}" >> "$tmp"
        chmod --reference="$hosts" "$tmp"; chown --reference="$hosts" "$tmp"
        sync -f "$tmp"
        plain_root_file "$hosts" && current=$(file_sha "$hosts") && [[ $current == "$before" ]] || die 'hosts 在更新期间发生变化，已保留原文件。'
        mv -T --no-copy -- "$tmp" "$hosts"; sync -f /etc; dirty
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
    official_apt_prepare
    official_apt_ready || die 'The verified APT indexes are unavailable. Resume to repeat the official update before configuration.'
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
    submit_reboot
}
submit_reboot() {
    check_ssh "${S[ssh_port]}"
    IN_REBOOT=yes
    if ! systemctl reboot --no-block; then
        IN_REBOOT=no
        die 'Cannot submit the reboot request. Inspect the error, then run the same script with --resume.'
    fi
    exit 0
}
consume_reboot() {
    [[ ${S[reboot_wait]} != none ]] || return 0
    local transition
    transition=$(boot_transition "${S[boot_before]}" "$(boot_id)" "${S[reboot_count]}" "${S[target_kernel]}" "$(uname -r)") || die 'Reboot verification failed: unexpected kernel or invalid state.'
    [[ $transition != WAIT ]] || die 'A recorded reboot has not happened. Inspect the error, then run the same script with --resume.'
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
    local mode probe
    mode=$(balloon_kernel_mode) || die 'Cannot read a definitive balloon kernel configuration.'
    if [[ ${S[balloon]} == module ]]; then
        [[ $mode == module ]] && cmp -s "$BALLOON_CONF" <(balloon_content) || die 'Balloon persistent configuration differs.'
        probe=$(modprobe -n -v virtio_balloon) || die 'Cannot inspect the balloon module load rule.'
        [[ $probe == 'install /bin/false '* || $probe == 'install /bin/false' ]] || die 'Balloon load prevention is not effective.'
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
            S[balloon]=module; S[last_config_boot]=$(boot_id); request_reboot balloon
        fi
    else S[balloon]=absent; save_state; fi
    verify_balloon
    S[phase]=final; save_state
}
verify_configuration() {
    [[ $(uname -r) == "${S[target_kernel]}" ]] || die 'Running kernel differs from target.'
    plain_root_file "/boot/vmlinuz-${S[target_kernel]}" && nv_kernel_image_matches "/boot/vmlinuz-${S[target_kernel]}" "$(uname -r)" "$(uname -v)" || die 'Running kernel build differs from the target boot image.'
    check_ssh "${S[ssh_port]}"
    [[ $(hostnamectl --static) == "${S[hostname]}" ]] && getent hosts "${S[hostname]}" >/dev/null || die 'Hostname did not persist.'
    [[ $(timedatectl show -p Timezone --value) == Asia/Kuala_Lumpur ]] || die 'Timezone did not persist.'
    ntp_observe; ntp_warning
    verify_balloon; verify_fail2ban
    cmp -s "$JAIL" <(jail_content) || die 'SSH jail persistent file differs.'
    if [[ ${S[swap_policy]} == disk ]]; then
        [[ ${S[swap_status]} == active || ${S[swap_status]} == verified ]] || die 'Disk Swap preparation is incomplete.'
        verify_swap
    fi
}
verify_all() {
    verify_configuration
    check_candidate "${S[kernel_meta]}"; check_candidate "linux-image-${S[target_kernel]}"
    local pkg pending
    for pkg in curl ca-certificates kmod tzdata fail2ban nftables; do check_candidate "$pkg"; done
    if [[ ${S[swap_policy]} == disk ]]; then check_candidate util-linux; fi
    pending=$(apt_run -s dist-upgrade --no-remove)
    if grep -q '^Inst ' <<< "$pending"; then die 'Package indexes now contain further upgrades; no success was declared.'; fi
}
snapshot_result() {
    local -a files=(/etc/hostname /etc/localtime "$JAIL") packages=(curl ca-certificates kmod tzdata fail2ban nftables "${S[kernel_meta]}" "linux-image-${S[target_kernel]}")
    local config_hashes package_versions pkg
    [[ ${S[balloon]} != module ]] || files+=("$BALLOON_CONF")
    if [[ ${S[swap_policy]} == disk ]]; then files+=("$SWAP_OWNER" "$SWAP_UNIT_FILE" "$SWAP_SYSCTL"); packages+=(util-linux); fi
    for pkg in "${packages[@]}"; do installed "$pkg" || die "Package is not fully installed: $pkg"; done
    config_hashes=$(sha256sum -- "${files[@]}" | sha256sum | awk '{print $1}') || die 'Cannot read all verified configuration files.'
    package_versions=$(dpkg-query -W -f='${binary:Package}=${Version},' "${packages[@]}") || die 'Cannot read all verified package versions.'
    if [[ ${1:-record} == verify ]]; then
        [[ $config_hashes == "${S[config_hashes]}" && $package_versions == "${S[packages]}" ]] || die 'Configuration or packages changed after verification; cleanup was stopped.'
        return 0
    fi
    S[config_hashes]=$config_hashes; S[packages]=$package_versions
    S[verified_boot]=$(boot_id); S[verified_at]=$(date +%s)
}
phase_final() {
    official_apt_prepare
    official_apt_ready || die 'The original official APT indexes are unavailable. Use --resume to repeat the update and recheck the selected kernel.'
    if [[ ${S[last_config_boot]} == "$(boot_id)" ]]; then request_reboot final; fi
    verify_all
    snapshot_result
    if [[ ${S[swap_policy]} == disk ]]; then S[swap_status]=verified; fi
    S[phase]=cleanup; S[result_status]=cleanup_pending
    save_state; write_state_to "$RESULT"
}
prepare_resume_plan() {
    if [[ ${S[phase]} == configure ]]; then
        # Refresh and select the target together after an interrupted setup.
        S[phase]=update
    elif [[ ${S[phase]} == final && ${S[reboot_wait]} == none ]] && ! official_apt_ready; then
        # The approved index snapshot was lost. Start a new verification plan
        # without recreating Swap or replacing existing configuration.
        S[phase]=update; S[target_kernel]=-; S[balloon]=pending
        S[boot_before]=-; S[reboot_count]=0
        note '原软件索引不完整。将重新读取 Debian 官方索引、选择内核并执行重启验收。'
    fi
}
verify_task_files() {
    [[ -d $BASE && ! -L $BASE && $(stat -c %u "$BASE") == 0 && $(stat -c %a "$BASE") == 700 ]] || die 'Task directory is unsafe.'
    plain_root_file "$BASE/owner" && [[ $(cat "$BASE/owner") == "${S[task_id]}" ]] || die 'Task directory ownership marker does not match.'
    plain_root_file "$WORKER" && [[ $(file_sha "$WORKER") == "${S[worker_sha]}" ]] || die 'Worker identity changed.'
    local file
    for file in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
        [[ -e $file || -L $file ]] || continue
        case $file in
            "$WORKER"|"$STATE_FILE"|"$BASE/owner"|"$BASE/next-vps-setup.log") [[ ! -L $file && -f $file ]] || die "Unexpected task file type: $file" ;;
            "$BASE/.state-pending") state_stage_file_ok "$file" || die 'Unsafe interrupted state write.' ;;
            "$BASE/swap-staged") [[ ${S[phase]} == swap && ${S[swap_status]} == building ]] && safe_swap_dir "$file" || die 'Unexpected Swap staging directory.' ;;
            *) die "Unknown task residual, automatic deletion refused: $file" ;;
        esac
    done
}
cleanup_success() {
    [[ ${S[result_status]} == cleanup_pending ]] || die 'Cleanup lacks a verified receipt.'
    verify_configuration; snapshot_result verify; verify_task_files
    write_state_to "$RESULT"
    if [[ -e $UNIT_FILE || -L $UNIT_FILE ]]; then
        plain_root_file "$UNIT_FILE" && cmp -s "$UNIT_FILE" <(unit_content) || die 'Temporary unit was changed; it was not removed.'
        # Do not reload a still-running oneshot after removing its definition:
        # systemd can replace TimeoutStartSec=infinity with the manager default
        # and kill a legitimate long-running cleanup. No unit file remains.
        systemctl --no-reload disable "$UNIT"
        rm -- "$UNIT_FILE"
    fi
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
    if [[ ${IN_REBOOT:-no} == yes && ( $code == 143 || $code == 129 ) ]]; then exit 0; fi
    [[ $code != 0 ]] || code=1
    bootstrap_temp_cleanup || printf '%s\n' 'Bootstrap temporary file identity changed; it was retained for inspection.' >&2
    if [[ -n ${BOOTSTRAP_BASE_ID:-} && -d $BASE && ! -L $BASE &&
          $(file_identity "$BASE") == "$BOOTSTRAP_BASE_ID" && ! -e $BASE/owner && ! -L $BASE/owner ]]; then
        rmdir -- "$BASE" 2>/dev/null || true
    fi
    nv_ui_heading '初始化未完成 · 已停止自动执行' >&2
    printf '出错阶段：%s\n查看原因：tail -n 100 %s/next-vps-setup.log\n修复后恢复：bash %s --resume\n' "$(nv_ui_stage_name "${S[phase]:-unknown}")" "$BASE" "${S[entry_path]:-/root/next-vps-setup.sh}" >&2
    if [[ -n ${S[phase]:-} ]]; then
        if [[ ${S[result_status]:-} == complete ]]; then S[phase]=cleanup; S[result_status]=cleanup_pending; fi
        S[failed]=yes
        if [[ -e $STATE_FILE ]] && bootstrap_dir_ok && plain_root_file "$BASE/owner" &&
           [[ $(cat "$BASE/owner") == "${S[task_id]}" ]] && plain_root_file "$STATE_FILE"; then
            save_state || true
        fi
        if write_state_to "$RESULT"; then
            publish_login_notice failure || printf '%s\n' '提醒：首次登录通知未能保存，请使用结果查询命令查看失败状态。' >&2
        fi
    fi
    exit "$code"
}
worker_main() {
    [[ $0 == "$WORKER" ]] || die 'Worker must run from its managed path.'
    plain_root_file "$STATE_FILE" && parse_state "$STATE_FILE" || die 'Invalid or unsafe state file.'
    [[ ${S[format]} == 4 ]] || die '旧任务必须使用原版本脚本恢复。'
    [[ ${S[machine_id]} == "$(cat /etc/machine-id)" ]] || die 'State belongs to another machine.'
    [[ ${S[failed]} == no ]] || die 'Previous failure requires repair and an explicit --resume; no automatic retry.'
    trap 'on_worker_error "$?"' ERR
    # Explicit die also runs the EXIT trap so failures cannot be retried at boot.
    trap 'code=$?; if ((code!=0)); then on_worker_error "$code"; fi' EXIT
    trap 'on_worker_error 143' TERM
    trap 'on_worker_error 129' HUP
    trap 'on_worker_error 130' INT
    check_os; verify_task_files; discard_interrupted_state_write
    plain_root_file "$UNIT_FILE" && cmp -s "$UNIT_FILE" <(unit_content) || die '后台初始化服务文件与本任务不一致。'
    nv_task_require_unit_definition "$UNIT" "$UNIT_FILE"
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
    swap_summary
    if [[ ${S[failed]} == yes ]]; then
        printf '%s\n' '结果：未完成，任务已停止。请先查看日志，再使用同一版本恢复。'
        printf '  tail -n 100 %s/next-vps-setup.log\n' "$BASE"
    elif [[ ${S[result_status]} == complete ]]; then
        printf '%s\n' '结果：初始化完成，重启核验通过。'
    elif nv_task_show_unit_failure "$UNIT"; then :
    elif [[ ${S[result_status]} == cleanup_pending ]]; then
        printf '%s\n' '结果：配置核验通过，任务文件尚未清理完成。请使用同一版本 --resume。'
    else printf '%s\n' '结果：尚未完成。后台可能仍在执行，请查看日志。'; fi
    if [[ ${S[ntp_status]:-pending} == unsynchronized || ${S[ntp_status]:-pending} == unavailable ]]; then
        printf '%s\n' '提醒：验收时尚未完成网络校时；系统继续使用当前时间。'
    fi
}
launch_worker() {
    local current_boot
    # Once a task exists, a failed systemd handoff is a task failure too.
    trap 'on_worker_error "$?"' ERR
    trap 'code=$?; if ((code!=0)); then on_worker_error "$code"; fi' EXIT
    trap 'on_worker_error 143' TERM; trap 'on_worker_error 129' HUP; trap 'on_worker_error 130' INT
    plain_root_file "$UNIT_FILE" && cmp -s "$UNIT_FILE" <(unit_content) || die 'Temporary service identity differs; it was not started.'
    systemctl daemon-reload || die 'Cannot reload the initialization service definition.'
    nv_task_require_unit_definition "$UNIT" "$UNIT_FILE"
    systemctl enable "$UNIT" || die 'Cannot enable initialization after reboot.'
    systemctl reset-failed "$UNIT" || die 'Cannot reset the initialization service failure.'
    write_state_to "$RESULT"
    if [[ ${S[reboot_wait]} != none ]]; then
        current_boot=$(boot_id) || die 'Cannot read the current boot identity.'
        if [[ $current_boot == "${S[boot_before]}" ]]; then
            # This branch is reached only from an explicit --resume. Re-submit
            # the already recorded restart, without spending a second slot.
            nv_ui_heading '正在重新提交已记录的重启请求'
            note '重启后任务将自动继续，届时请手动重连 SSH。'
            submit_reboot
        fi
    fi
    systemctl start --no-block "$UNIT" || die 'Cannot submit the initialization start request.'
    flock -u 9 || die 'Cannot release the initialization handoff lock.'
    exec 9<&- || die 'Cannot close the initialization handoff lock.'
    trap - ERR EXIT TERM HUP INT
    nv_ui_launch "next-vps-setup $VERSION" '5–10' "$RESULT" "$BASE/next-vps-setup.log"
}
bootstrap_dir_ok() {
    [[ -d $BASE && ! -L $BASE && $(readlink -e -- "$BASE") == "$BASE" &&
       $(stat -c %u -- "$BASE") == 0 && $(stat -c %a -- "$BASE") == 700 ]]
}
bootstrap_temp_cleanup() {
    [[ -n ${BOOTSTRAP_TEMP:-} ]] || return 0
    [[ $BOOTSTRAP_TEMP == "$BASE"/.bootstrap-* && -n ${BOOTSTRAP_TEMP_ID:-} ]] || return 1
    if [[ -e $BOOTSTRAP_TEMP || -L $BOOTSTRAP_TEMP ]]; then
        plain_root_file "$BOOTSTRAP_TEMP" && [[ $(stat -c %h -- "$BOOTSTRAP_TEMP") == 1 &&
            $(file_identity "$BOOTSTRAP_TEMP") == "$BOOTSTRAP_TEMP_ID" ]] || return 1
        rm -- "$BOOTSTRAP_TEMP" || return 1
    fi
    BOOTSTRAP_TEMP=; BOOTSTRAP_TEMP_ID=
}
bootstrap_temp_create() {
    [[ -z ${BOOTSTRAP_TEMP:-} ]] || die 'A bootstrap temporary file is already tracked.'
    BOOTSTRAP_TEMP=$(mktemp "$BASE/.bootstrap-$1.XXXXXX") || return 1
    BOOTSTRAP_TEMP_ID=$(file_identity "$BOOTSTRAP_TEMP") || return 1
}
write_owner() {
    [[ ! -e $BASE/owner && ! -L $BASE/owner ]] || die 'An owner marker already exists; it was not overwritten.'
    bootstrap_temp_create owner
    if ! printf '%s\n' "${S[task_id]}" > "$BOOTSTRAP_TEMP" || ! chmod 0600 "$BOOTSTRAP_TEMP" || ! sync -f "$BOOTSTRAP_TEMP"; then
        bootstrap_temp_cleanup || true; die 'Cannot prepare the task owner marker.'
    fi
    if ! mv -T -- "$BOOTSTRAP_TEMP" "$BASE/owner"; then bootstrap_temp_cleanup || true; die 'Cannot publish the task owner marker.'; fi
    BOOTSTRAP_TEMP=; BOOTSTRAP_TEMP_ID=
    sync -f "$BASE"
}
copy_worker() {
    local entry=$1
    [[ ! -e $WORKER && ! -L $WORKER ]] || die 'A worker already exists; it was not overwritten.'
    bootstrap_temp_create worker
    if ! cp -- "$entry" "$BOOTSTRAP_TEMP" || ! chmod 0700 "$BOOTSTRAP_TEMP" ||
       [[ $(file_sha "$BOOTSTRAP_TEMP") != "${S[worker_sha]}" || $(file_sha "$entry") != "${S[worker_sha]}" ]] || ! sync -f "$BOOTSTRAP_TEMP"; then
        bootstrap_temp_cleanup || true; die 'Cannot prepare an identical task worker.'
    fi
    if ! mv -T -- "$BOOTSTRAP_TEMP" "$WORKER"; then bootstrap_temp_cleanup || true; die 'Cannot publish the task worker.'; fi
    BOOTSTRAP_TEMP=; BOOTSTRAP_TEMP_ID=
    sync -f "$BASE"
}
bootstrap_pending() {
    [[ ${S[phase]} == swap && ${S[result_status]} == running && ${S[target_kernel]} == - &&
       ${S[swap_status]} == pending && ${S[swap_uuid]} == - && ${S[swap_identity]} == - &&
       ${S[reboot_count]} == 0 && ${S[reboot_wait]} == none && ${S[boot_before]} == - &&
       ${S[balloon]} == pending && ${S[ntp_status]} == pending && ${S[entry_sha]} == "${S[worker_sha]}" ]]
}
prepare_bootstrap_recovery() {
    local entry=$1 file
    bootstrap_pending || die 'Receipt is not an initial bootstrap recovery point.'
    [[ ${S[machine_id]} == "$(cat /etc/machine-id)" ]] || die 'Bootstrap belongs to another machine.'
    safe_entry_path "$entry" && [[ $entry == "${S[entry_path]}" && $(file_sha "$entry") == "${S[worker_sha]}" ]] || die 'Bootstrap recovery requires the original path and identical payload.'
    trap 'on_worker_error "$?"' ERR
    trap 'code=$?; if ((code!=0)); then on_worker_error "$code"; fi' EXIT
    trap 'on_worker_error 143' TERM; trap 'on_worker_error 129' HUP; trap 'on_worker_error 130' INT
    if [[ ! -e $BASE && ! -L $BASE ]]; then
        [[ ! -e $UNIT_FILE && ! -L $UNIT_FILE ]] || die 'A service without its bootstrap directory requires inspection.'
        mkdir -m 0700 -- "$BASE"; BOOTSTRAP_BASE_ID=$(file_identity "$BASE")
        write_owner
    fi
    bootstrap_dir_ok || die 'Unsafe bootstrap recovery directory.'
    plain_root_file "$BASE/owner" && [[ $(stat -c %h -- "$BASE/owner") == 1 && $(cat "$BASE/owner") == "${S[task_id]}" ]] || die 'Unowned or foreign bootstrap data was not adopted.'
    for file in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
        [[ -e $file || -L $file ]] || continue
        case $file in
            "$WORKER"|"$STATE_FILE"|"$BASE/owner"|"$BASE/next-vps-setup.log") plain_root_file "$file" || die 'Unsafe bootstrap recovery file.' ;;
            "$BASE/.state-pending") state_stage_file_ok "$file" || die 'Unsafe interrupted state write.' ;;
            *) die 'Unknown bootstrap residual; it was not changed.' ;;
        esac
    done
    if [[ -e $WORKER || -L $WORKER ]]; then
        plain_root_file "$WORKER" && [[ $(stat -c %h -- "$WORKER") == 1 && $(file_sha "$WORKER") == "${S[worker_sha]}" ]] || die 'Bootstrap worker changed; it was not overwritten.'
    else save_state; copy_worker "$entry"; fi
    verify_task_files
    S[entry_identity]=$(file_identity "$entry"); S[entry_sha]=$(file_sha "$entry"); S[failed]=no
    save_state; write_state_to "$RESULT"
    [[ -e $UNIT_FILE || -L $UNIT_FILE ]] || publish_config "$UNIT_FILE" "$(unit_content)"
    launch_worker
}
prepare_cleanup_recovery() {
    local entry=$1 file
    [[ ${S[phase]} == cleanup && ${S[result_status]} == cleanup_pending ]] || die 'Receipt is not a cleanup recovery point.'
    safe_entry_path "$entry" && [[ $(file_sha "$entry") == "${S[worker_sha]}" ]] || die 'Cleanup recovery requires the same root-owned script version.'
    [[ $entry == "${S[entry_path]}" ]] || die 'For cleanup recovery, upload the same script to the original entry path shown in the receipt.'
    trap 'on_worker_error "$?"' ERR
    trap 'code=$?; if ((code!=0)); then on_worker_error "$code"; fi' EXIT
    trap 'on_worker_error 143' TERM; trap 'on_worker_error 129' HUP; trap 'on_worker_error 130' INT
    if [[ -e $BASE || -L $BASE ]]; then
        [[ -d $BASE && ! -L $BASE && $(stat -c %u "$BASE") == 0 && $(stat -c %a "$BASE") == 700 ]] || die 'Unsafe task directory.'
        for file in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
            [[ -e $file || -L $file ]] || continue
            case $file in
                "$WORKER"|"$STATE_FILE"|"$BASE/owner"|"$BASE/next-vps-setup.log") plain_root_file "$file" || die 'Unsafe cleanup residual.' ;;
                "$BASE/.state-pending") state_stage_file_ok "$file" && [[ -f $BASE/owner && ! -L $BASE/owner ]] || die 'Unsafe interrupted state write.' ;;
                *) die "Unknown cleanup residual: $file" ;;
            esac
        done
        if [[ -e $BASE/owner ]]; then [[ $(cat "$BASE/owner") == "${S[task_id]}" ]] || die 'Task marker differs from receipt.'; fi
        if [[ -e $WORKER ]]; then [[ $(file_sha "$WORKER") == "${S[worker_sha]}" ]] || die 'Worker differs from receipt.'; fi
    else mkdir -m 0700 -- "$BASE"; fi
    if [[ -e $UNIT_FILE || -L $UNIT_FILE ]]; then
        plain_root_file "$UNIT_FILE" && cmp -s "$UNIT_FILE" <(unit_content) || die 'Temporary service differs from this version.'
    fi
    # Only an explicit same-version --resume can adopt this freshly uploaded copy.
    S[entry_identity]=$(file_identity "$entry"); S[entry_sha]=$(file_sha "$entry"); S[failed]=no
    [[ -e $BASE/owner ]] || write_owner
    save_state
    [[ -e $WORKER ]] || copy_worker "$entry"
    [[ -e $UNIT_FILE ]] || publish_config "$UNIT_FILE" "$(unit_content)"
    launch_worker
}
initialize_task() {
    local entry=$1 name port meta owner pkg hash memory swap_bytes swap_policy policy_sha apt_root
    meta=$(kernel_meta_for_abi "$(uname -r)") || die 'Unsupported kernel flavour; only Debian 13 stable cloud/standard amd64 kernels are supported.'
    safe_entry_path "$entry" || die 'Upload a root-owned, non-symlink copy under /root, not writable by other users.'
    [[ ! -e $BASE && ! -L $BASE && ! -e $UNIT_FILE && ! -L $UNIT_FILE ]] || die 'Unknown task files exist; no files were overwritten.'
    apt_root=$(official_apt_root)
    [[ ! -e $apt_root && ! -L $apt_root ]] || die 'An existing private APT directory requires inspection; it was not changed.'
    [[ ! -e $JAIL && ! -L $JAIL && ! -e $BALLOON_CONF && ! -L $BALLOON_CONF ]] || die 'Existing initialization configuration found; this entry is for a fresh system.'
    fresh_fail2ban_preflight
    cloud_init_preflight
    [[ -t 0 ]] || die 'First run requires an interactive terminal.'
    nv_ui_heading "next-vps-setup $VERSION · Debian 13 初始化"
    printf '%s\n\n' '将更新官方软件包、配置基础防护，并自动重启验收。' 'SSH 账号、密码、端口和认证方式保持现有配置。' '网络校时不可用时会提醒并继续。请先确认备份和商家控制台可用。'
    printf '机器名（例如 hk-vps）: '; IFS= read -r name
    validate_hostname "$name" || die '机器名格式无效。请使用字母、数字、短横线或点，不要包含空格。'
    printf '当前实际 SSH 端口（仅核验，不修改）: '; IFS= read -r port
    validate_port "$port" || die 'SSH 端口无效。请输入 1 到 65535 的数字。'
    check_ssh "$port"; check_sources; check_resources
    pkg=linux-image-$(uname -r)
    installed "$pkg" || die 'Running kernel is not owned by the expected Debian kernel package.'
    owner=$(dpkg-query -W -f='${Maintainer}' "$pkg")
    [[ $owner == *'Debian Kernel Team'* ]] || die 'Unknown kernel package maintainer.'
    memory=$(memtotal) && swap_bytes=$(swap_target_bytes "$memory") || die '无法读取有效的 MemTotal。'
    swap_policy=$(swap_plan "$memory" "$swap_bytes") || die 'Swap 预检未通过，系统初始化尚未开始。'
    hash=$(file_sha "$entry")
    policy_sha=$(ssh_policy_sha) || die 'Cannot read the effective SSH authentication policy.'
    S=([format]=4 [task_id]="$(cat /proc/sys/kernel/random/uuid)" [machine_id]="$(cat /etc/machine-id)"
       [hostname]="$name" [ssh_port]="$port" [kernel_meta]="$meta" [target_kernel]=- [ntp_unit]="$(detect_ntp)"
       [balloon]=pending [swap_policy]="$swap_policy" [swap_bytes]="$swap_bytes" [swap_status]=pending [swap_uuid]=- [swap_identity]=- [mem_kib]="$memory" [phase]=swap
       [boot_before]=- [last_config_boot]="$(boot_id)" [reboot_count]=0 [reboot_wait]=none [failed]=no
       [entry_path]="$entry" [entry_identity]="$(file_identity "$entry")" [entry_sha]="$hash" [worker_sha]="$hash"
       [ssh_policy_sha]="$policy_sha" [result_status]=running [verified_boot]=- [verified_at]=0 [config_hashes]=- [packages]=- [ntp_status]=pending)
    printf '系统内存：%s KiB\n' "$memory"
    swap_summary
    trap 'on_worker_error "$?"' ERR
    trap 'code=$?; if ((code!=0)); then on_worker_error "$code"; fi' EXIT
    trap 'on_worker_error 143' TERM; trap 'on_worker_error 129' HUP; trap 'on_worker_error 130' INT
    write_state_to "$RESULT"
    mkdir -m 0700 -- "$BASE"; BOOTSTRAP_BASE_ID=$(file_identity "$BASE")
    write_owner
    save_state
    copy_worker "$entry"
    verify_task_files
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
    safe_state_parent /var/lib || die 'Unsafe state parent directory; ownership or permissions require inspection.'
    nv_task_lock "$mode"
    if [[ $mode == --worker ]]; then worker_main; return; fi
    if [[ $mode == --resume && -e $UNIT_FILE ]]; then nv_task_check_resume "$UNIT"; fi
    entry=$(readlink -e -- "$0") || die 'Execute a regular local file, not stdin or a pipe.'
    if [[ -e $STATE_FILE || -L $STATE_FILE ]]; then
        plain_root_file "$STATE_FILE" && parse_state "$STATE_FILE" || die 'Unsupported or invalid task state; this version cannot resume a different release. No state was changed.'
        [[ ${S[format]} == 4 ]] || die '旧任务必须使用原版本脚本恢复。'
        [[ ${S[machine_id]} == "$(cat /etc/machine-id)" ]] || die 'State belongs to another machine.'
        print_status
        if [[ $mode == --resume ]]; then
            safe_entry_path "$entry" && [[ $entry == "${S[entry_path]}" && $(file_sha "$entry") == "${S[worker_sha]}" ]] || die '恢复任务需要原路径、相同内容的脚本文件。'
            if [[ ${S[phase]} == cleanup ]]; then prepare_cleanup_recovery "$entry"; return 0; fi
            if bootstrap_pending; then prepare_bootstrap_recovery "$entry"; return 0; fi
            verify_task_files
            S[entry_identity]=$(file_identity "$entry"); S[entry_sha]=$(file_sha "$entry")
            prepare_resume_plan
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
        if [[ $mode == --resume ]]; then
            if bootstrap_pending; then prepare_bootstrap_recovery "$entry"; else prepare_cleanup_recovery "$entry"; fi
            return 0
        fi
        die 'Task preparation or cleanup was interrupted. Retain this receipt and use the identical original file with --resume after inspecting the cause.'
    fi
    [[ $mode == start ]] || die 'No existing task or receipt.'
    [[ $0 == /* && ! -L $0 && -f $0 ]] || die 'Use bash followed by an absolute regular file under /root.'
    initialize_task "$entry"
}
main "$@"
