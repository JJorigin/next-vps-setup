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
