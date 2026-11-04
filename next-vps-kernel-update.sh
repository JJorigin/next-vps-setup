#!/bin/bash
# next-vps-kernel-update 1.2 -- Debian 13 official-kernel maintenance.
# Save under /root; run with bash and an absolute path. No network tuning.
# Functions may be sourced by the isolated test harness; main is not then run.

VERSION=1.2
BASE=/var/lib/next-vps-kernel-update
STATE=$BASE/state.tsv
WORKER=$BASE/worker.sh
LOG=$BASE/run.log
RESULT=/var/lib/next-vps-kernel-update-result.tsv
PURGE_MANIFEST=$BASE/purge.tsv
UNIT=next-vps-kernel-update.service
UNIT_FILE=/etc/systemd/system/next-vps-kernel-update.service
INIT_RESULT=/var/lib/next-vps-setup-result.tsv
BOOT_DIR=/boot
PROC_DIR=/proc
SYS_DIR=/sys
declare -A S=()
REBOOTING=no
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
    nv_notice_install next-vps-kernel-update "$1" "${S[task_id]}" "${S[phase]}" not-recorded "${S[entry]}"
}
sha() { sha256sum -- "$1" | awk '{print $1}'; }
identity() { stat -c '%d:%i' -- "$1"; }
installed() { [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]; }
uuid_ok() { [[ $1 =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; }
boot_id() { local v; v=$(cat "$PROC_DIR/sys/kernel/random/boot_id"); uuid_ok "$v" || return 1; printf '%s\n' "$v"; }
plain_file() {
    local mode
    [[ -f $1 && ! -L $1 && $(stat -c %u -- "$1") == 0 && $(stat -c %h -- "$1") == 1 ]] || return 1
    mode=$(stat -c %a -- "$1") || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 022) == 0 ))
}
safe_dir() {
    local p=$1 mode
    while :; do
        [[ -d $p && ! -L $p && $(stat -c %u -- "$p") == 0 ]] || return 1
        mode=$(stat -c %a -- "$p") || return 1
        (( (8#$mode & 022) == 0 )) || return 1
        [[ $p != / ]] || break
        p=${p%/*}; [[ -n $p ]] || p=/
    done
}
safe_entry() { [[ $1 == /root/*.sh && $1 =~ ^/root/[a-zA-Z0-9_./-]+\.sh$ && $(readlink -e -- "$1") == "$1" ]] && plain_file "$1" && safe_dir "${1%/*}"; }
abi_ok() {
    local meta=$1 abi=$2
    [[ $abi =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z0-9.+-]*-amd64$ ]] || return 1
    case $meta in
        linux-image-cloud-amd64) [[ $abi == *-cloud-amd64 && $abi != *-rt-* ]] ;;
        linux-image-amd64) [[ $abi != *-cloud-* && $abi != *-rt-* && $abi != *-unsigned* ]] ;;
        *) return 1 ;;
    esac
}
version_ok() { [[ $1 =~ ^[0-9][a-zA-Z0-9.+:~_-]*$ ]]; }
# Print package<TAB>ABI<TAB>Debian-package-version. Never sort ABI strings.
parse_dependency() {
    local meta=$1 dep=$2 pkg abi version
    if [[ $dep =~ ^(linux-image-([a-z0-9.+-]+))\ \(=\ ([0-9][a-zA-Z0-9.+:~_-]*)\)$ ]]; then
        pkg=${BASH_REMATCH[1]}; abi=${BASH_REMATCH[2]}; version=${BASH_REMATCH[3]}
        abi_ok "$meta" "$abi" && version_ok "$version" || return 1
        printf '%s\t%s\t%s\n' "$pkg" "$abi" "$version"
    else return 1; fi
}
inventory() { dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${Maintainer}\n' 'linux-image*'; }
# Reject mixed/custom/newer images; include both installed and config-only old
# images, so an earlier manual `remove` does not leave package configuration.
select_old() {
    local meta=$1 target=$2 wanted=$3 data=$4 status pkg version maintainer abi target_seen=no meta_seen=no
    version_ok "$wanted" || return 1
    while IFS=$'\t' read -r status pkg version maintainer; do
        [[ $status == installed || $status == config-files ]] || continue
        if [[ $pkg == "$meta" ]]; then [[ $status == installed ]] || return 1; meta_seen=yes; continue; fi
        [[ $pkg != linux-image-amd64 && $pkg != linux-image-cloud-amd64 ]] || return 1
        [[ $pkg == linux-image-* && $maintainer == *'Debian Kernel Team'* ]] || return 1
        abi=${pkg#linux-image-}; abi_ok "$meta" "$abi" && version_ok "$version" || return 1
        if [[ $pkg == "$target" ]]; then
            [[ $status == installed && $version == "$wanted" ]] || return 1
            target_seen=yes
        else
            dpkg --compare-versions "$version" lt "$wanted" || return 1
            printf '%s\n' "$pkg"
        fi
    done <<< "$data"
    [[ $target_seen == yes && $meta_seen == yes ]]
}
validate_purge_plan() {
    local plan=$1 expected=$2 op pkg rest n=0
    declare -A allowed=() seen=()
    while IFS= read -r pkg; do [[ -z $pkg ]] || allowed[$pkg]=1; done <<< "$expected"
    while read -r op pkg rest; do
        case $op in
            Inst|Conf|Remv) return 1 ;;
            Purg)
                pkg=${pkg%:amd64}
                [[ -v allowed[$pkg] && ! -v seen[$pkg] ]] || return 1
                seen[$pkg]=1; n=$((n+1)) ;;
        esac
    done <<< "$plan"
    (( n == ${#allowed[@]} && n > 0 ))
}
validate_install_plan() {
    local op pkg rest
    while read -r op pkg rest; do
        case $op in Remv|Purg) return 1 ;; esac
    done <<< "$1"
}
# APT protocol v2 is inspected while APT owns the package transaction locks.
# This closes the gap between the earlier human-readable simulation and dpkg.
validate_purge_protocol() {
    local expected=$1 line pkg old direction new action extra header_done=no n=0
    declare -A allowed=() seen=()
    while IFS=$'\t' read -r pkg old; do
        [[ $pkg =~ ^linux-image-[0-9][a-z0-9.+-]*-amd64$ ]] && version_ok "$old" && [[ ! -v allowed[$pkg] ]] || return 1
        allowed[$pkg]=$old
    done <<< "$expected"
    IFS= read -r line && [[ $line == 'VERSION 2' ]] || return 1
    while IFS= read -r line; do
        if [[ -z $line ]]; then header_done=yes; break; fi
        [[ $line == *=* ]] || return 1
    done
    [[ $header_done == yes ]] || return 1
    while read -r pkg old direction new action extra || [[ -n ${pkg:-}${old:-}${direction:-}${new:-}${action:-}${extra:-} ]]; do
        [[ $pkg =~ ^linux-image-[0-9][a-z0-9.+-]*-amd64$ && -z $extra ]] || return 1
        [[ -v allowed[$pkg] && ! -v seen[$pkg] ]] || return 1
        [[ $old == "${allowed[$pkg]}" && $direction == '>' && $new == - && $action == '**REMOVE**' ]] || return 1
        seen[$pkg]=1; n=$((n+1))
    done
    (( n>0 && n==${#allowed[@]} ))
}
apt_guard() {
    [[ $0 == "$WORKER" && ${APT_HOOK_INFO_FD:-} == 0 ]] || die 'Invalid APT guard invocation.'
    load_state "$STATE" && [[ ${S[phase]} == purge && ${S[failed]} == no ]] || die 'APT guard has no approved purge state.'
    [[ ${S[machine_id]} == "$(cat /etc/machine-id)" && $(sha "$WORKER") == "${S[script_sha]}" ]] || die 'APT guard identity mismatch.'
    boot_ready "${S[boot_before]}" "$(boot_id)" "${S[target_abi]}" "$(uname -r)" || die 'APT guard cannot verify the new boot.'
    plain_file "$BOOT_DIR/vmlinuz-${S[target_abi]}" && nv_kernel_image_matches "$BOOT_DIR/vmlinuz-${S[target_abi]}" "$(uname -r)" "$(uname -v)" || die 'APT guard cannot confirm the running target kernel build.'
    local parsed expected_target
    installed "${S[meta]}" && installed "${S[target_pkg]}" || die 'APT guard cannot find the installed target and metapackage.'
    [[ $(dpkg-query -W -f='${Version}' "${S[meta]}") == "${S[meta_version]}" &&
       $(dpkg-query -W -f='${Version}' "${S[target_pkg]}") == "${S[target_version]}" ]] || die 'Target package versions changed before the actual transaction.'
    parsed=$(parse_dependency "${S[meta]}" "$(dpkg-query -W -f='${Depends}' "${S[meta]}")") || die 'Invalid in-transaction target dependency.'
    expected_target=$(printf '%s\t%s\t%s' "${S[target_pkg]}" "${S[target_abi]}" "${S[target_version]}")
    [[ $parsed == "$expected_target" ]] || die 'Target dependency changed before the actual transaction.'
    plain_file "$PURGE_MANIFEST" && [[ ${S[purge_sha]} != - && $(sha "$PURGE_MANIFEST") == "${S[purge_sha]}" ]] || die 'Approved purge manifest changed.'
    local pkg version expected; expected=$(cat "$PURGE_MANIFEST")
    while IFS=$'\t' read -r pkg version; do
        [[ $pkg != "${S[target_pkg]}" && $pkg != "linux-image-$(uname -r)" ]] || die 'APT guard refuses the running/target kernel.'
        abi_ok "${S[meta]}" "${pkg#linux-image-}" && version_ok "$version" &&
            dpkg --compare-versions "$version" lt "${S[target_version]}" || die 'APT guard refuses a non-older or unknown kernel.'
        [[ $(dpkg-query -W -f='${Version}' "$pkg") == "$version" &&
           $(dpkg-query -W -f='${Maintainer}' "$pkg") == *'Debian Kernel Team'* ]] || die 'Approved old package identity changed.'
    done <<< "$expected"
    validate_purge_protocol "$expected" || die 'Actual APT transaction differs from the approved old-kernel purge.'
}
boot_ready() { uuid_ok "$1" && uuid_ok "$2" && [[ $1 != "$2" && $3 == "$4" ]]; }

state_keys() {
    printf '%s\n' format version task_id machine_id phase failed result_status meta meta_version target_pkg target_abi target_version boot_before verified_boot reboots entry entry_id script_sha config_sha ssh_sha swap_sha swappiness services balloon removed verified_at purge_sha
}
value_ok() {
    local key=$1 v=$2
    [[ -n $v && $v != *[[:cntrl:]]* ]] || return 1
    case $key in
        format) [[ $v == 1 ]] ;; version) [[ $v == "$VERSION" ]] ;;
        task_id|boot_before) uuid_ok "$v" ;;
        verified_boot) [[ $v == - ]] || uuid_ok "$v" ;;
        machine_id) [[ $v =~ ^[a-f0-9]{32}$ ]] ;;
        phase) [[ $v == install || $v == reboot || $v == verify || $v == purge || $v == cleanup || $v == done ]] ;;
        failed) [[ $v == yes || $v == no ]] ;;
        result_status) [[ $v == running || $v == cleanup_pending || $v == complete ]] ;;
        meta) [[ $v == linux-image-cloud-amd64 || $v == linux-image-amd64 ]] ;;
        meta_version|target_version) [[ $v == - ]] || version_ok "$v" ;;
        target_pkg) [[ $v == - || $v =~ ^linux-image-[0-9][a-z0-9.+-]*-amd64$ ]] ;;
        target_abi) [[ $v == - || $v =~ ^[0-9][a-z0-9.+-]*-amd64$ ]] ;;
        reboots) [[ $v == 0 || $v == 1 ]] ;;
        entry) [[ $v == /root/* && $v =~ ^/[a-zA-Z0-9_./-]+$ ]] ;;
        entry_id) [[ $v =~ ^[0-9]+:[0-9]+$ ]] ;;
        script_sha|config_sha|ssh_sha|swap_sha) [[ $v =~ ^[a-f0-9]{64}$ ]] ;;
        purge_sha) [[ $v == - || $v =~ ^[a-f0-9]{64}$ ]] ;;
        swappiness) [[ $v =~ ^[0-9]{1,3}$ ]] && ((10#$v<=200)) ;;
        services) [[ $v == ssh.service,fail2ban.service || $v == ssh.service,fail2ban.service,x-ui.service ]] ;;
        balloon) [[ $v == module || $v == absent ]] ;;
        removed) [[ $v == - || $v =~ ^linux-image-[a-z0-9.+,-]+$ ]] ;;
        verified_at) [[ $v =~ ^[0-9]{1,12}$ ]] ;;
        *) return 1 ;;
    esac
}
validate_state() {
    local key count=0
    while IFS= read -r key; do
        [[ -v S[$key] ]] && value_ok "$key" "${S[$key]}" || return 1
        count=$((count+1))
    done < <(state_keys)
    (( ${#S[@]} == count )) || return 1
    if [[ ${S[target_pkg]} == - ]]; then
        [[ ${S[phase]} == install && ${S[target_abi]} == - && ${S[target_version]} == - && ${S[meta_version]} == - ]] || return 1
    else
        [[ ${S[target_pkg]} == "linux-image-${S[target_abi]}" && ${S[target_version]} != - && ${S[meta_version]} != - ]] || return 1
        abi_ok "${S[meta]}" "${S[target_abi]}" || return 1
    fi
    [[ ${S[phase]} == install || ${S[target_pkg]} != - ]] || return 1
    case ${S[phase]} in
        install) [[ ${S[reboots]} == 0 && ${S[result_status]} == running && ${S[verified_boot]} == - ]] || return 1 ;;
        reboot) [[ ${S[result_status]} == running && ${S[verified_boot]} == - ]] || return 1 ;;
        verify|purge) [[ ${S[reboots]} == 1 && ${S[result_status]} == running && ${S[verified_boot]} == - ]] || return 1 ;;
        cleanup) [[ ${S[result_status]} == cleanup_pending ]] || return 1 ;;
        done) [[ ${S[result_status]} == complete ]] || return 1 ;;
    esac
    if [[ ${S[result_status]} != running ]]; then
        [[ ${S[phase]} == cleanup || ${S[phase]} == done ]] || return 1
        [[ ${S[verified_boot]} != - && ${S[reboots]} == 1 && ${S[verified_at]} != 0 ]] || return 1
        [[ ${S[verified_boot]} != "${S[boot_before]}" ]] || return 1
    fi
    [[ ${S[result_status]} != complete || ( ${S[phase]} == done && ${S[failed]} == no ) ]]
}
load_state() {
    local path=$1 line key value octets
    S=()
    plain_file "$path" && (( $(stat -c %s -- "$path") <= 32768 )) || return 1
    octets=$(od -An -tx1 -- "$path") || return 1
    if grep -Eq '(^|[[:space:]])00([[:space:]]|$)' <<< "$octets"; then return 1; fi
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *$'\t'* ]] || return 1
        key=${line%%$'\t'*}; value=${line#*$'\t'}
        [[ $key =~ ^[a-z_]+$ && $value != *$'\t'* && ! -v S[$key] ]] || return 1
        value_ok "$key" "$value" || return 1
        S[$key]=$value
    done < "$path"
    validate_state
}
save_to() {
    local path=$1 parent=${1%/*} tmp key
    validate_state && safe_dir "$parent" && [[ ! -L $path ]] || die 'Unsafe state destination or invalid state.'
    tmp=$(mktemp "$parent/.kernel-update.XXXXXX") || return 1
    if ! serialize_state > "$tmp" || ! chmod 0600 "$tmp" || ! sync -f "$tmp"; then
        rm -- "$tmp" || true; return 1
    fi
    if ! mv -T -- "$tmp" "$path"; then rm -- "$tmp" || true; return 1; fi
    sync -f "$parent" || return 1
}
serialize_state() {
    local key
    while IFS= read -r key; do printf '%s\t%s\n' "$key" "${S[$key]}" || return 1; done < <(state_keys)
}
save_state() { save_to "$STATE"; }
receipt_field() {
    local path=$1 key=$2
    awk -F '\t' -v k="$key" '$1==k {n++; if(NF!=2)bad=1; v=$2} END{if(n!=1||bad)exit 1; print v}' "$path"
}
previous_complete() {
    plain_file "$RESULT" && (( $(stat -c %s -- "$RESULT") <= 32768 )) || return 1
    [[ $(receipt_field "$RESULT" format) == 1 && $(receipt_field "$RESULT" phase) == done &&
       $(receipt_field "$RESULT" result_status) == complete && $(receipt_field "$RESULT" failed) == no &&
       $(receipt_field "$RESULT" machine_id) == "$(cat /etc/machine-id)" ]] || return 1
    uuid_ok "$(receipt_field "$RESULT" task_id)"
}
check_initialization() {
    plain_file "$INIT_RESULT" || die 'A completed next-vps-setup receipt is required.'
    [[ $(receipt_field "$INIT_RESULT" phase) == done && $(receipt_field "$INIT_RESULT" result_status) == complete && $(receipt_field "$INIT_RESULT" failed) == no ]] || die 'Initialization has not completed.'
    [[ $(receipt_field "$INIT_RESULT" machine_id) == "$(cat /etc/machine-id)" ]] || die 'Initialization receipt belongs to another machine.'
    [[ ! -e /var/lib/next-vps-setup && ! -e /etc/systemd/system/next-vps-setup.service ]] || die 'An initialization task still exists.'
}
check_os() {
    [[ $(id -u) == 0 ]] || die 'Run as root.'
    grep -Eq '^ID=(debian|"debian")$' /etc/os-release && grep -Eq '^VERSION_ID=(13|"13")$' /etc/os-release || die 'Debian 13 is required.'
    [[ $(dpkg --print-architecture) == amd64 && -d /run/systemd/system ]] || die 'amd64 and systemd are required.'
    if systemd-detect-virt --container --quiet; then die 'Containers are unsupported.'; fi
    systemd-detect-virt --vm --quiet || die 'A virtual machine is required.'
    local cmd audit held
    for cmd in apt-get apt-cache awk cat chmod cmp cp date df dpkg dpkg-query env fail2ban-client find flock grep hostnamectl id install mktemp modprobe mv od python3 readlink rm rmdir sha256sum sleep sort ss stat swapon sync sysctl systemctl systemd-detect-virt timedatectl uname; do
        command -v "$cmd" >/dev/null || die "Missing prerequisite: $cmd"
    done
    audit=$(dpkg --audit); [[ -z $audit ]] || die 'Incomplete dpkg operations exist; repair them before continuing.'
    held=$(dpkg --get-selections | awk '$2=="hold"{print $1}')
    if grep -Eq '^linux-image($|-)' <<< "$held"; then die 'Held kernel packages exist; no holds were changed.'; fi
    check_initialization
}
check_space() {
    local root_free boot_free available
    root_free=$(df -Pk / | awk 'END{print $4}'); boot_free=$(df -Pk "$BOOT_DIR" | awk 'END{print $4}')
    available=$(awk '$1=="MemAvailable:"{print $2}' "$PROC_DIR/meminfo")
    [[ $root_free =~ ^[0-9]+$ && $boot_free =~ ^[0-9]+$ && $available =~ ^[0-9]+$ ]] || die 'Cannot read available resources.'
    (( root_free>=524288 && boot_free>=204800 && available>=131072 )) || die 'Need at least 512 MiB free on /, 200 MiB on /boot, and 128 MiB MemAvailable.'
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
    local keyring
    # Host source files, pins and APT hooks are neither loaded nor changed.
    id -u _apt >/dev/null 2>&1 || die '系统缺少 APT 下载沙箱用户，请先修复基础软件包。'
    keyring=$(official_apt_keyring_target) || die 'Debian 官方密钥文件缺失、权限异常或链接目标不受支持，请保留 ls -l /usr/share/keyrings/debian-archive-keyring.* 的输出供排查。'
    (( (8#$(stat -c %a -- "$keyring") & 004) != 0 )) || die 'APT 下载沙箱无法读取 Debian 签名密钥，请检查文件权限。'
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
    local -a paths=()
    root=$(official_apt_root)
    official_apt_dir_ok "$root" || return 1
    official_apt_collect_paths "$root" paths || return 1
    for path in "${paths[@]}"; do
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
    for directory in parts sourceparts preferencesparts trustedparts authparts lists lists/partial archives archives/partial; do
        if [[ ! -e $root/$directory && ! -L $root/$directory ]]; then mkdir -m 0755 -- "$root/$directory"; fi
        case $directory in lists/partial|archives/partial) official_apt_dir_ok "$root/$directory" download ;; *) official_apt_dir_ok "$root/$directory" ;; esac || die 'Unsafe private APT subdirectory.'
    done
    official_apt_publish "$root/empty.conf" ''
    official_apt_publish "$root/preferences" ''
    official_apt_publish "$root/auth.conf" ''
    content=$(official_apt_sources_content); official_apt_publish "$root/official.sources" "$content"$'\n'
    content=$(official_apt_config_content); official_apt_publish "$root/apt.conf" "$content"$'\n'
    official_apt_check_tree || die '更新暂存目录出现未知内容或权限变化，已停止，请保留现场检查。'
    official_apt_clear_partial_links || die '无法安全清理本次官方索引的中断链接，请保留现场检查。'
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
    local -a paths=()
    root=$(official_apt_root)
    [[ -e $root || -L $root ]] || return 0
    official_apt_file_ok "$root/owner" && [[ $(cat "$root/owner") == "${S[task_id]}" ]] || die '更新暂存目录不属于本次任务，未执行清理。'
    official_apt_check_tree || die '更新暂存目录含有未知内容，未执行清理，请保留现场检查。'
    official_apt_clear_partial_links || die '本次官方索引的中断链接未能安全清理，未继续删除。'
    # Delete only the previously checked regular files; never recurse with rm.
    official_apt_collect_paths "$root" paths || return 1
    for path in "${paths[@]}"; do
        [[ ! -f $path || -L $path || $path == "$root/owner" ]] || rm -- "$path" || return 1
    done
    for path in lists/partial lists/auxfiles lists archives/partial archives parts sourceparts preferencesparts trustedparts authparts; do
        [[ ! -d $root/$path ]] || rmdir -- "$root/$path" || return 1
    done
    rm -- "$root/owner" || return 1
    rmdir -- "$root" || return 1
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

candidate() { apt_cache policy "$1" | awk '$1=="Candidate:"{n++;v=$2} END{if(n!=1||v=="(none)")exit 1; print v}'; }
indexed_version() {
    local pkg=$1 version=$2 output; output=$(apt_cache policy "$pkg")
    awk -v v="$version" '
        $1=="***" && NF==3 {active=($2==v);next}
        NF==2 && $2~/^[0-9]+$/ {active=($1==v);next}
        active && $1~/^[0-9]+$/ && $2~/^(https?:\/\/|mirror\+file:)/ && $3~/^trixie(-security|-updates)?\// {found=1}
        END{exit !found}' <<< "$output"
}
choose_meta() {
    local meta other running
    running=$(uname -r)
    case $running in *-cloud-amd64) meta=linux-image-cloud-amd64; other=linux-image-amd64 ;; *-amd64) meta=linux-image-amd64; other=linux-image-cloud-amd64 ;; *) die 'Unrecognized running kernel.' ;; esac
    abi_ok "$meta" "$running" && installed "$meta" && ! installed "$other" || die 'Kernel family or metapackage is missing, mixed or unsupported.'
    [[ $(receipt_field "$INIT_RESULT" kernel_meta) == "$meta" ]] || die 'Kernel family differs from the initialization receipt.'
    installed "linux-image-$running" || die 'The running kernel package is not installed.'
    [[ $(dpkg-query -W -f='${Maintainer}' "linux-image-$running") == *'Debian Kernel Team'* ]] || die 'The running kernel is not a recognized Debian kernel.'
    printf '%s\n' "$meta"
}
target_from_index() {
    local version dep record
    version=$(candidate "${S[meta]}"); version_ok "$version" && indexed_version "${S[meta]}" "$version" || die 'Metapackage candidate has no official index.'
    record=$(apt_cache show "${S[meta]}=$version")
    dep=$(awk '/^Depends: /{sub(/^Depends: /,"");print}' <<< "$record" | sort -u)
    local parsed; parsed=$(parse_dependency "${S[meta]}" "$dep") || die 'Unsupported metapackage dependency structure.'
    IFS=$'\t' read -r 'S[target_pkg]' 'S[target_abi]' 'S[target_version]' <<< "$parsed"
    S[meta_version]=$version
    indexed_version "${S[target_pkg]}" "${S[target_version]}" || die 'Target kernel version has no official index.'
    local current; current=$(dpkg-query -W -f='${Version}' "${S[meta]}")
    dpkg --compare-versions "$current" le "$version" || die 'A kernel metapackage downgrade would be required.'
}
balloon_mode() {
    local v; v=$(grep -E '^(CONFIG_VIRTIO_BALLOON=|# CONFIG_VIRTIO_BALLOON is not set$)' "$BOOT_DIR/config-$1") || return 1
    case $v in CONFIG_VIRTIO_BALLOON=m) echo module ;; '# CONFIG_VIRTIO_BALLOON is not set') echo absent ;; *) return 1 ;; esac
}
ssh_hash() { /usr/sbin/sshd -T | sort | sha256sum | awk '{print $1}'; }
ssh_listening() {
    local configured listeners
    configured=$(/usr/sbin/sshd -T | awk '$1=="port"{print $2}' | sort -u) || return 1
    listeners=$(ss -H -lntp | awk '/"sshd"/{n=split($4,a,":");print a[n]}' | sort -u) || return 1
    [[ -n $configured && $configured == "$listeners" ]]
}
swap_hash() { swapon --show --noheadings --raw --bytes --output NAME,SIZE,PRIO | sort | sha256sum | awk '{print $1}'; }
config_hash() {
    local file
    for file in /etc/hostname /etc/localtime /etc/passwd /etc/shadow /etc/group /etc/gshadow \
        /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf /etc/sysctl.conf /etc/sysctl.d/*.conf \
        /etc/modprobe.d/*.conf /etc/fail2ban/jail.d/99-next-vps-setup.local \
        /etc/systemd/system/var-lib-nextvpssetup-swapfile.swap /var/lib/nextvpssetup/owner.tsv; do
        [[ -e $file || -L $file ]] || continue
        [[ -f $file && -r $file ]] || return 1
        sha256sum --zero -- "$file" || return 1
        printf '%s\0' "$(stat -c '%u:%g:%a' -- "$file")"
        if [[ -L $file ]]; then readlink -- "$file" || return 1; fi
    done | sha256sum | awk '{print $1}'
}
snapshot() {
    /usr/sbin/sshd -t
    systemctl is-active --quiet ssh.service && systemctl is-active --quiet fail2ban.service || die 'SSH and Fail2ban must already be running.'
    ssh_listening && fail2ban-client status sshd >/dev/null || die 'SSH listeners or the SSH jail are not ready.'
    S[services]=ssh.service,fail2ban.service
    if systemctl is-active --quiet x-ui.service; then S[services]=${S[services]},x-ui.service; fi
    S[ssh_sha]=$(ssh_hash); S[swap_sha]=$(swap_hash); S[config_sha]=$(config_hash)
    S[swappiness]=$(sysctl -n vm.swappiness)
    S[balloon]=$(balloon_mode "$(uname -r)") || die 'Balloon driver is built-in or its kernel configuration is unknown.'
    [[ ! -d $SYS_DIR/module/virtio_balloon ]] || die 'Balloon driver is loaded.'
    if [[ ${S[balloon]} == module ]]; then
        local probe; probe=$(modprobe -n -v virtio_balloon)
        [[ $probe == 'install /bin/false' || $probe == 'install /bin/false '* ]] || die 'Existing balloon load prevention is ineffective.'
    fi
}
verify_preserved() {
    local services unit ready attempt
    [[ $(config_hash) == "${S[config_sha]}" ]] || die 'Persistent settings changed; inspect them before deleting old kernels.'
    /usr/sbin/sshd -t
    [[ $(ssh_hash) == "${S[ssh_sha]}" ]] || die 'Effective SSH policy changed.'
    [[ $(swap_hash) == "${S[swap_sha]}" && $(sysctl -n vm.swappiness) == "${S[swappiness]}" ]] || die 'Swap or swappiness did not persist.'
    IFS=, read -r -a services <<< "${S[services]}"
    for ((attempt=0; attempt<30; attempt++)); do
        ready=yes
        for unit in "${services[@]}"; do systemctl is-active --quiet "$unit" || ready=no; done
        ssh_listening || ready=no
        fail2ban-client status sshd >/dev/null 2>&1 || ready=no
        [[ $ready != yes ]] || break
        sleep 2
    done
    [[ $ready == yes ]] || die 'A previously active critical service did not recover; no automatic service changes were made.'
    [[ $(balloon_mode "${S[target_abi]}") != '' && ! -d $SYS_DIR/module/virtio_balloon ]] || die 'Balloon protection failed.'
    if [[ $(balloon_mode "${S[target_abi]}") == module ]]; then
        local probe; probe=$(modprobe -n -v virtio_balloon)
        [[ $probe == 'install /bin/false' || $probe == 'install /bin/false '* ]] || die 'Balloon module load prevention is ineffective.'
    fi
}
verify_target() {
    local parsed pkg abi version
    official_apt_recover_indexes
    boot_ready "${S[boot_before]}" "$(boot_id)" "${S[target_abi]}" "$(uname -r)" || die 'The planned new boot and target kernel have not both been verified.'
    [[ $(dpkg-query -W -f='${Version}' "${S[meta]}") == "${S[meta_version]}" && $(candidate "${S[meta]}") == "${S[meta_version]}" ]] || die 'Kernel metapackage or candidate changed during this task.'
    parsed=$(parse_dependency "${S[meta]}" "$(dpkg-query -W -f='${Depends}' "${S[meta]}")") || die 'Installed metapackage dependency is unsupported.'
    IFS=$'\t' read -r pkg abi version <<< "$parsed"
    [[ $pkg == "${S[target_pkg]}" && $abi == "${S[target_abi]}" && $version == "${S[target_version]}" ]] || die 'Installed kernel dependency differs from the recorded target.'
    installed "$pkg" && [[ $(dpkg-query -W -f='${Version}' "$pkg") == "$version" ]] || die 'Target kernel package is not fully installed at the required version.'
    [[ -s $BOOT_DIR/vmlinuz-$abi && -s $BOOT_DIR/initrd.img-$abi && -r $BOOT_DIR/config-$abi ]] || die 'Target boot files are missing.'
    plain_file "$BOOT_DIR/vmlinuz-$abi" && nv_kernel_image_matches "$BOOT_DIR/vmlinuz-$abi" "$(uname -r)" "$(uname -v)" || die 'The running kernel build differs from the target boot image.'
    [[ -z $(dpkg --audit) ]] || die 'dpkg reports incomplete packages.'
    apt_run check
    verify_preserved
}

unit_content() {
    cat <<'EOF'
[Unit]
Description=next-vps-kernel-update and verified old-kernel cleanup
Wants=network-online.target
After=network-online.target ssh.service fail2ban.service
ConditionPathExists=/var/lib/next-vps-kernel-update/state.tsv

[Service]
Type=oneshot
ExecStart=/bin/bash /var/lib/next-vps-kernel-update/worker.sh --worker
TimeoutStartSec=infinity
Restart=no
StandardInput=null
StandardOutput=append:/var/lib/next-vps-kernel-update/run.log
StandardError=append:/var/lib/next-vps-kernel-update/run.log
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}
verify_owned() {
    local f
    safe_dir "$BASE" && [[ $(stat -c %a -- "$BASE") == 700 ]] || die 'Unsafe task directory.'
    plain_file "$BASE/owner" && [[ $(cat "$BASE/owner") == "${S[task_id]}" ]] || die 'Task ownership mismatch.'
    plain_file "$WORKER" && [[ $(sha "$WORKER") == "${S[script_sha]}" ]] || die 'Worker payload changed.'
    for f in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
        [[ -e $f || -L $f ]] || continue
        case $f in "$WORKER"|"$STATE"|"$LOG"|"$BASE/owner"|"$PURGE_MANIFEST") plain_file "$f" || die 'Unsafe task file.' ;; *) die "Unknown task residual: $f" ;; esac
    done
}
bootstrap_temp_cleanup() {
    [[ -n ${BOOTSTRAP_TEMP:-} ]] || return 0
    [[ $BOOTSTRAP_TEMP == "$BASE"/.bootstrap-* && -n ${BOOTSTRAP_TEMP_ID:-} ]] || return 1
    if [[ -e $BOOTSTRAP_TEMP || -L $BOOTSTRAP_TEMP ]]; then
        plain_file "$BOOTSTRAP_TEMP" && [[ $(identity "$BOOTSTRAP_TEMP") == "$BOOTSTRAP_TEMP_ID" ]] || return 1
        rm -- "$BOOTSTRAP_TEMP" || return 1
    fi
    BOOTSTRAP_TEMP=; BOOTSTRAP_TEMP_ID=
}
bootstrap_temp_create() {
    [[ -z ${BOOTSTRAP_TEMP:-} ]] || die 'A bootstrap temporary file is already tracked.'
    BOOTSTRAP_TEMP=$(mktemp "$BASE/.bootstrap-$1.XXXXXX") || return 1
    BOOTSTRAP_TEMP_ID=$(identity "$BOOTSTRAP_TEMP") || return 1
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
       [[ $(sha "$BOOTSTRAP_TEMP") != "${S[script_sha]}" || $(sha "$entry") != "${S[script_sha]}" ]] || ! sync -f "$BOOTSTRAP_TEMP"; then
        bootstrap_temp_cleanup || true; die 'Cannot prepare an identical task worker.'
    fi
    if ! mv -T -- "$BOOTSTRAP_TEMP" "$WORKER"; then bootstrap_temp_cleanup || true; die 'Cannot publish the task worker.'; fi
    BOOTSTRAP_TEMP=; BOOTSTRAP_TEMP_ID=
    sync -f "$BASE"
}
bootstrap_pending() {
    [[ ${S[phase]} == install && ${S[result_status]} == running && ${S[reboots]} == 0 &&
       ${S[target_pkg]} == - && ${S[target_abi]} == - && ${S[target_version]} == - && ${S[meta_version]} == - ]]
}
write_unit() {
    local tmp
    [[ ! -e $UNIT_FILE && ! -L $UNIT_FILE ]] || die 'A maintenance service already exists.'
    safe_dir "${UNIT_FILE%/*}" || die 'Unsafe maintenance service directory.'
    tmp=$(mktemp "${UNIT_FILE%/*}/.next-vps-kernel-update.XXXXXX")
    if ! unit_content > "$tmp" || ! chmod 0644 "$tmp" || ! sync -f "$tmp"; then
        rm -- "$tmp" || true; die 'Cannot prepare maintenance service.'
    fi
    if ! mv -T -- "$tmp" "$UNIT_FILE"; then rm -- "$tmp" || true; die 'Cannot publish maintenance service.'; fi
    sync -f "${UNIT_FILE%/*}"
}
launch() {
    trap 'on_error "$?"' ERR
    trap 'code=$?; if ((code!=0)); then on_error "$code"; fi' EXIT
    trap 'on_error 143' TERM; trap 'on_error 129' HUP; trap 'on_error 130' INT
    plain_file "$UNIT_FILE" && cmp -s "$UNIT_FILE" <(unit_content) || die 'Maintenance service identity mismatch.'
    systemctl daemon-reload
    [[ $(systemctl show "$UNIT" -p FragmentPath --value) == "$UNIT_FILE" && -z $(systemctl show "$UNIT" -p DropInPaths --value) ]] || die 'Unexpected maintenance service source or overrides.'
    systemctl enable "$UNIT"; systemctl reset-failed "$UNIT"
    save_to "$RESULT"
    flock -u 9; exec 9<&-
    systemctl start --no-block "$UNIT"
    trap - ERR EXIT TERM HUP INT
    nv_ui_launch "next-vps-setup $VERSION · 内核维护" '3–10' "$RESULT" "$LOG"
}
install_target() {
    local plan parsed pkg abi version old
    strict_update
    target_from_index; save_state
    plan=$(apt_run -s --no-remove --no-install-recommends install "${S[meta]}=${S[meta_version]}")
    printf '%s\n' "$plan"; validate_install_plan "$plan" || die 'The install simulation would remove packages.'
    # Reject pre-existing mixed/newer images before installing or requesting a reboot.
    local inv status name ver maintainer
    inv=$(inventory)
    while IFS=$'\t' read -r status name ver maintainer; do
        [[ $status == installed || $name == "${S[meta]}" ]] || continue
        [[ $name != "${S[meta]}" ]] || continue
        [[ $maintainer == *'Debian Kernel Team'* ]] && abi_ok "${S[meta]}" "${name#linux-image-}" || die 'Mixed or unknown kernel packages are installed.'
        dpkg --compare-versions "$ver" le "${S[target_version]}" || die 'A newer kernel is already installed; no old kernel was deleted.'
    done <<< "$inv"
    apt_run -y --no-remove --no-install-recommends install "${S[meta]}=${S[meta_version]}"
    [[ -z $(dpkg --audit) ]] || die 'Kernel installation left incomplete packages.'
    apt_run check
    parsed=$(parse_dependency "${S[meta]}" "$(dpkg-query -W -f='${Depends}' "${S[meta]}")") || die 'Cannot identify installed target kernel.'
    IFS=$'\t' read -r pkg abi version <<< "$parsed"
    [[ $pkg == "${S[target_pkg]}" && $abi == "${S[target_abi]}" && $version == "${S[target_version]}" ]] || die 'Installed dependency differs from the approved target.'
    installed "$pkg" && [[ $(dpkg-query -W -f='${Version}' "$pkg") == "$version" ]] || die 'Target package version differs.'
    [[ -s $BOOT_DIR/vmlinuz-$abi && -s $BOOT_DIR/initrd.img-$abi && -r $BOOT_DIR/config-$abi ]] || die 'Target boot files are missing.'
    balloon_mode "$abi" >/dev/null || die 'Target kernel has built-in/unknown balloon support; old kernels were not deleted.'
    [[ $(config_hash) == "${S[config_sha]}" ]] || die 'Persistent configuration changed during installation; inspect before rebooting.'
    S[phase]=reboot; save_state
}
purge_old() {
    local inv old plan pkg status
    verify_target
    inv=$(inventory)
    old=$(select_old "${S[meta]}" "${S[target_pkg]}" "${S[target_version]}" "$inv") || die 'Unknown, mixed, equal-version or newer kernel found; no purge was started.'
    if [[ -n $old ]]; then
        local -a selectors=()
        while IFS= read -r pkg; do selectors+=("?exact-name($pkg)"); done <<< "$old"
        plan=$(apt_run -s purge "${selectors[@]}")
        printf '%s\n' "$plan"
        validate_purge_plan "$plan" "$old" || die 'Purge simulation includes operations outside the exact old-kernel list.'
        verify_target
        [[ $(inventory) == "$inv" ]] || die 'Kernel package inventory changed after simulation.'
        # Persist an exact package+version allowlist for the in-transaction hook.
        if [[ -e $PURGE_MANIFEST || -L $PURGE_MANIFEST ]]; then plain_file "$PURGE_MANIFEST" || die 'Unsafe purge manifest.'; fi
        : > "$PURGE_MANIFEST"
        while IFS= read -r pkg; do
            printf '%s\t%s\n' "$pkg" "$(dpkg-query -W -f='${Version}' "$pkg")" >> "$PURGE_MANIFEST"
        done <<< "$old"
        chmod 0600 "$PURGE_MANIFEST"; sync -f "$PURGE_MANIFEST"
        S[purge_sha]=$(sha "$PURGE_MANIFEST"); save_state
        # APT owns its transaction locks. Its hooks maintain initramfs and GRUB.
        apt_run -o "DPkg::Pre-Install-Pkgs::=$WORKER --apt-guard" \
            -o "DPkg::Tools::Options::$WORKER::Version=2" -o "DPkg::Tools::Options::$WORKER::InfoFD=0" \
            -y purge "${selectors[@]}"
        while IFS= read -r pkg; do
            status=$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null) || status=absent
            [[ $status == absent || $status == not-installed ]] || die 'An old kernel package was not fully purged.'
        done <<< "$old"
        if [[ ${S[removed]} == - ]]; then S[removed]=${old//$'\n'/,}; else S[removed]=${S[removed]},${old//$'\n'/,}; fi
    fi
    verify_target
    old=$(select_old "${S[meta]}" "${S[target_pkg]}" "${S[target_version]}" "$(inventory)") || die 'Final kernel inventory is unsupported.'
    [[ -z $old ]] || die 'Old installed kernel packages remain.'
    S[verified_boot]=$(boot_id); S[verified_at]=$(date +%s)
    S[phase]=cleanup; S[result_status]=cleanup_pending; save_state; save_to "$RESULT"
}
cleanup() {
    local remaining
    verify_target; verify_owned
    remaining=$(select_old "${S[meta]}" "${S[target_pkg]}" "${S[target_version]}" "$(inventory)") || die 'Cleanup inventory is unsupported.'
    [[ -z $remaining ]] || die 'Old kernels appeared after verification; cleanup was stopped.'
    [[ ${S[result_status]} == cleanup_pending ]] || die 'No verified cleanup receipt.'
    save_to "$RESULT"
    apt_run clean
    # The hook is staged now but cannot display success until RESULT is final.
    publish_login_notice success
    if [[ -e $UNIT_FILE || -L $UNIT_FILE ]]; then
        plain_file "$UNIT_FILE" && cmp -s "$UNIT_FILE" <(unit_content) || die 'Maintenance unit changed; not deleting it.'
        # A reload after unlink would drop the running oneshot's infinite
        # startup timeout; keep its in-memory definition until it exits.
        systemctl --no-reload disable "$UNIT"; rm -- "$UNIT_FILE"; sync -f "${UNIT_FILE%/*}"
    fi
    if [[ -e ${S[entry]} || -L ${S[entry]} ]]; then
        safe_entry "${S[entry]}" && [[ $(identity "${S[entry]}") == "${S[entry_id]}" && $(sha "${S[entry]}") == "${S[script_sha]}" ]] || die 'Entry changed; it was not deleted.'
        rm -- "${S[entry]}"
        sync -f "${S[entry]%/*}"
    fi
    verify_owned
    official_apt_cleanup
    [[ ! -e $PURGE_MANIFEST ]] || rm -- "$PURGE_MANIFEST"
    rm -- "$STATE" "$BASE/owner" "$WORKER"
    [[ ! -e $LOG ]] || rm -- "$LOG"
    rmdir -- "$BASE"
    S[phase]=done; S[result_status]=complete; S[failed]=no; save_to "$RESULT"
    nv_ui_heading '内核维护已完成 · 新内核启动核验通过'
    note "当前内核：${S[target_abi]}；已清理旧内核；结果：$RESULT"
}
on_error() {
    local code=${1:-1}
    trap - ERR EXIT TERM HUP INT
    if [[ $REBOOTING == yes && $code == 143 ]]; then exit 0; fi
    (( code!=0 )) || code=1
    bootstrap_temp_cleanup || printf '%s\n' 'Bootstrap temporary file identity changed; it was retained for inspection.' >&2
    # Before the owner is published, only remove our own still-empty directory.
    # A killed process or an unknown residual is never adopted on a later run.
    if [[ -n ${BOOTSTRAP_BASE_ID:-} && -d $BASE && ! -L $BASE &&
          $(identity "$BASE") == "$BOOTSTRAP_BASE_ID" && ! -e $BASE/owner && ! -L $BASE/owner ]]; then
        rmdir -- "$BASE" 2>/dev/null || true
    fi
    nv_ui_heading '内核维护未完成 · 已停止自动执行' >&2
    printf '出错阶段：%s\n查看原因：tail -n 100 %s\n修复后恢复：bash %s --resume\n' "$(nv_ui_stage_name "${S[phase]:-unknown}")" "$LOG" "${S[entry]:-/root/next-vps-kernel-update.sh}" >&2
    if [[ -n ${S[phase]:-} ]]; then
        if [[ ${S[result_status]:-} == complete ]]; then S[phase]=cleanup; S[result_status]=cleanup_pending; fi
        S[failed]=yes
        if [[ -e $STATE ]] && safe_dir "$BASE" && [[ $(stat -c %a -- "$BASE") == 700 ]] &&
           plain_file "$BASE/owner" && [[ $(cat "$BASE/owner") == "${S[task_id]}" ]] && plain_file "$STATE"; then
            save_state || true
        fi
        if save_to "$RESULT"; then
            publish_login_notice failure || printf '%s\n' '提醒：首次登录通知未能保存，请查看维护结果文件。' >&2
        fi
    fi
    exit "$code"
}
worker() {
    [[ $0 == "$WORKER" ]] || die 'Invalid worker path.'
    load_state "$STATE" || die 'Invalid task state.'
    [[ ${S[machine_id]} == "$(cat /etc/machine-id)" && ${S[failed]} == no ]] || die 'Wrong machine or a failed task requires explicit --resume.'
    trap 'on_error "$?"' ERR
    trap 'code=$?; if ((code!=0)); then on_error "$code"; fi' EXIT
    trap 'on_error 143' TERM; trap 'on_error 129' HUP; trap 'on_error 130' INT
    check_os; verify_owned
    while :; do
        nv_ui_progress "${S[phase]}"
        case ${S[phase]} in
            install) install_target ;;
            reboot)
                # Do not call the stage in a conditional: that disables errexit inside it.
                if [[ ${S[reboots]} == 0 ]]; then
                    S[boot_before]=$(boot_id); S[reboots]=1; save_state
                    nv_ui_heading '即将自动重启 · 旧内核暂时保留'
                    note '新内核启动核验通过后才会清理旧版本。请稍后使用原 SSH 账号和端口手动重连。'
                    sync; REBOOTING=yes; systemctl reboot
                    return 0
                fi
                [[ $(boot_id) != "${S[boot_before]}" ]] || die 'Reboot has not occurred; reboot manually after inspecting the task.'
                S[phase]=verify; save_state ;;
            verify) verify_target; note "Running kernel build: $(uname -v)"; S[phase]=purge; save_state ;;
            purge) purge_old ;;
            cleanup) cleanup; return 0 ;;
            done) return 0 ;;
            *) die 'Unknown task phase.' ;;
        esac
    done
}
print_status() {
    nv_ui_heading "next-vps-setup $VERSION · 内核维护状态"
    printf '当前阶段：%s\n目标内核：%s\n软件包版本：%s\n已请求重启：%s 次\n' "$(nv_ui_stage_name "${S[phase]}")" "${S[target_abi]}" "${S[target_version]}" "${S[reboots]}"
    if [[ ${S[failed]} == yes ]]; then
        printf '结果：任务未完成，已停止。请先查看日志：\n  tail -n 100 %s\n' "$LOG"
    elif [[ ${S[result_status]} == complete ]]; then
        printf '%s\n' '结果：新内核启动核验和旧内核清理均已完成。'
    elif [[ ${S[result_status]} == cleanup_pending ]]; then
        printf '%s\n' '结果：内核核验通过，任务文件尚未清理完成。请使用同一版本 --resume。'
    else printf '%s\n' '结果：尚未完成。后台可能仍在执行，请查看日志。'; fi
}
prepare() {
    local entry=$1 meta=$2 key
    safe_entry "$entry" || die 'Use an absolute, root-owned regular file under /root.'
    [[ ! -e $BASE && ! -L $BASE && ! -e $UNIT_FILE && ! -L $UNIT_FILE ]] || die 'Task paths already exist; nothing was overwritten.'
    [[ ! -L $RESULT ]] || die 'Result path is a symlink.'
    if [[ -e $RESULT ]]; then previous_complete || die 'An incomplete, invalid or foreign result requires inspection.'; fi
    S=([format]=1 [version]="$VERSION" [task_id]="$(cat "$PROC_DIR/sys/kernel/random/uuid")" [machine_id]="$(cat /etc/machine-id)"
       [phase]=install [failed]=no [result_status]=running [meta]="$meta" [meta_version]=- [target_pkg]=- [target_abi]=- [target_version]=-
       [boot_before]="$(boot_id)" [verified_boot]=- [reboots]=0 [entry]="$entry" [entry_id]="$(identity "$entry")" [script_sha]="$(sha "$entry")"
       [config_sha]=- [ssh_sha]=- [swap_sha]=- [swappiness]=0 [services]=ssh.service,fail2ban.service [balloon]=absent [removed]=- [verified_at]=0 [purge_sha]=-)
    snapshot
    # Replace an earlier completed receipt before launching the new task, so
    # even a failed worker copy cannot leave the earlier success as this result.
    trap 'on_error "$?"' ERR
    trap 'code=$?; if ((code!=0)); then on_error "$code"; fi' EXIT
    trap 'on_error 143' TERM; trap 'on_error 129' HUP; trap 'on_error 130' INT
    save_to "$RESULT"
    mkdir -m 0700 -- "$BASE"; BOOTSTRAP_BASE_ID=$(identity "$BASE")
    write_owner
    save_state
    copy_worker "$entry"
    verify_owned
    write_unit; launch
}
resume_task() {
    local entry=$1 recovery=no f bootstrap=no
    if [[ -e $STATE ]]; then
        load_state "$STATE" || die 'Invalid existing state.'
        if [[ ${S[phase]} == cleanup && ${S[result_status]} == cleanup_pending ]]; then recovery=yes; fi
    else
        load_state "$RESULT" || die 'No recoverable task.'
        if [[ ${S[result_status]} == cleanup_pending ]]; then recovery=yes
        elif bootstrap_pending; then bootstrap=yes
        else die 'No recoverable task.'; fi
    fi
    [[ ${S[machine_id]} == "$(cat /etc/machine-id)" ]] || die 'Task belongs to another machine.'
    safe_entry "$entry" && [[ $entry == "${S[entry]}" && $(sha "$entry") == "${S[script_sha]}" ]] || die 'Resume requires the same payload at its original /root path.'
    trap 'on_error "$?"' ERR
    trap 'code=$?; if ((code!=0)); then on_error "$code"; fi' EXIT
    trap 'on_error 143' TERM; trap 'on_error 129' HUP; trap 'on_error 130' INT
    if bootstrap_pending; then bootstrap=yes; fi
    if [[ $bootstrap == yes ]]; then
        if [[ ! -e $BASE && ! -L $BASE ]]; then
            [[ ! -e $UNIT_FILE && ! -L $UNIT_FILE ]] || die 'A service without its bootstrap directory requires inspection.'
            mkdir -m 0700 -- "$BASE"; BOOTSTRAP_BASE_ID=$(identity "$BASE")
            write_owner
        fi
        safe_dir "$BASE" && [[ $(stat -c %a -- "$BASE") == 700 ]] || die 'Unsafe bootstrap recovery directory.'
        plain_file "$BASE/owner" && [[ $(cat "$BASE/owner") == "${S[task_id]}" ]] || die 'Unowned or foreign bootstrap data was not adopted.'
        for f in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
            [[ -e $f || -L $f ]] || continue
            case $f in "$WORKER"|"$STATE"|"$LOG"|"$BASE/owner") plain_file "$f" || die 'Unsafe bootstrap recovery file.' ;; *) die 'Unknown bootstrap residual; it was not changed.' ;; esac
        done
        if [[ -e $WORKER || -L $WORKER ]]; then
            plain_file "$WORKER" && [[ $(sha "$WORKER") == "${S[script_sha]}" ]] || die 'Bootstrap worker changed; it was not overwritten.'
        else save_state; copy_worker "$entry"; fi
    elif [[ $recovery == yes ]]; then
        if [[ ! -e $BASE && ! -L $BASE ]]; then mkdir -m 0700 -- "$BASE"; fi
        safe_dir "$BASE" || die 'Unsafe recovery directory.'
        for f in "$BASE"/* "$BASE"/.[!.]* "$BASE"/..?*; do
            [[ -e $f || -L $f ]] || continue
            case $f in "$WORKER"|"$STATE"|"$LOG"|"$BASE/owner"|"$PURGE_MANIFEST") plain_file "$f" || die 'Unsafe recovery file.' ;; *) die 'Unknown recovery residual.' ;; esac
        done
        if [[ -e $BASE/owner ]]; then [[ $(cat "$BASE/owner") == "${S[task_id]}" ]] || die 'Recovery owner differs.'; fi
        if [[ -e $WORKER ]]; then [[ $(sha "$WORKER") == "${S[script_sha]}" ]] || die 'Recovery worker differs.'; fi
        [[ -e $BASE/owner ]] || write_owner
        [[ -e $WORKER ]] || copy_worker "$entry"
        S[entry_id]=$(identity "$entry")
    fi
    verify_owned
    # Re-upload after interrupted cleanup has a new inode; only explicit resume
    # with the recorded path and identical payload may adopt that new inode.
    S[entry_id]=$(identity "$entry")
    S[failed]=no; save_state; save_to "$RESULT"
    [[ -e $UNIT_FILE || -L $UNIT_FILE ]] || write_unit
    launch
}
main() {
    if [[ -z ${BASH_VERSION:-} ]]; then printf '%s\n' 'Run with bash.' >&2; exit 2; fi
    set -Eeuo pipefail
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
    unset APT_CONFIG UCF_FORCE_CONFFNEW UCF_FORCE_CONFFMISS
    umask 077
    local mode=${1:-start} entry meta
    (( $#<=1 )) || die 'Use no argument, --check, --status, --resume or --help.'
    case $mode in
        --help) printf '%s\n' "next-vps-kernel-update $VERSION" 'bash /root/next-vps-kernel-update.sh [--check|--status|--resume]' '自动重启一次；新启动核验后删除旧内核，仅保留目标内核和元包。'; return ;;
        start|--check|--status|--resume|--worker|--apt-guard) ;;
        *) die 'Unknown argument.' ;;
    esac
    [[ $(id -u) == 0 ]] || die 'Run as root.'
    if [[ $mode == --apt-guard ]]; then apt_guard; return; fi
    if [[ $mode == --status ]]; then
        if [[ -e $STATE || -L $STATE ]]; then load_state "$STATE" || die 'Invalid task state.'
        else load_state "$RESULT" || die 'No valid task or result.'; fi
        [[ ${S[machine_id]} == "$(cat /etc/machine-id)" ]] || die 'Wrong machine.'
        print_status; return
    fi
    if [[ $mode != --worker ]]; then check_os; fi
    safe_dir /var/lib || die 'Unsafe /var/lib.'
    exec 9</var/lib; flock -n 9 || die 'Another setup or kernel maintenance task is running.'
    if [[ $mode == --worker ]]; then worker; return; fi
    [[ $0 == /* && ! -L $0 && -f $0 ]] || die 'Use an absolute regular file path, not a symlink or stdin.'
    entry=$(readlink -e -- "$0") || die 'Save the script as a real local file.'
    safe_entry "$entry" || die 'Run an absolute root-owned /root copy.'
    if [[ $mode == --resume ]]; then resume_task "$entry"; return; fi
    if [[ -e $STATE || -L $STATE ]]; then
        load_state "$STATE" || die 'Invalid existing state.'
        [[ ${S[machine_id]} == "$(cat /etc/machine-id)" ]] || die 'Existing task belongs to another machine.'
        print_status; return
    fi
    check_sources; meta=$(choose_meta); check_space
    if [[ $mode == --check ]]; then
        S[meta]=$meta; snapshot
        printf 'CHECK_OK: meta=%s. 本机条件已通过；正式执行时将使用隔离的 Debian 官方索引确定目标。\n' "$meta"
        return
    fi
    nv_ui_heading "next-vps-setup $VERSION · 官方内核维护"
    printf '%s\n\n' '将更新原系列官方内核，自动重启一次，核验后删除全部旧内核。' '清理后没有旧内核可回退。请先备份，并确认能使用商家控制台。' '现有 SSH、交换空间和业务配置保持不变。'
    prepare "$entry" "$meta"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
