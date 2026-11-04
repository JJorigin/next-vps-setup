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
