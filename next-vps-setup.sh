#!/bin/bash
# next-vps-setup v1.0 -- local-file installation, root, Debian 13 amd64 VM.
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
VERSION=1.0
declare -A S=()
IN_REBOOT=no

die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
note() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
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
    [[ $path == /root/* && $path != *[[:cntrl:]]* ]] || return 1
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
    for command in apt-get apt-cache apt-config apt-mark awk blkid cat chmod chown cmp cp cut date dd df dpkg dpkg-query findmnt flock getconf getent grep hostnamectl id install ln mkdir mktemp mkswap modprobe mv od readlink rm rmdir sed sha256sum sleep sort ss stat swapon sync sysctl systemctl systemd-detect-virt timedatectl uname update-initramfs; do
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
    [[ -z $(apt-mark showhold) ]] || die 'Held packages exist; no holds were changed.'

}
validate_index_uri() {
    local uri=$1 base suite file line
    [[ $uri == */dists/* ]] || return 1
    base=${uri%%/dists/*}; suite=${uri#*/dists/}; suite=${suite%%/*}
    [[ $suite == trixie || $suite == trixie-updates || $suite == trixie-security ]] || return 1
    case $base in
        http://deb.debian.org/debian|https://deb.debian.org/debian|http://deb.debian.org/debian-security|https://deb.debian.org/debian-security|http://security.debian.org/debian-security|https://security.debian.org/debian-security) ;;
        mirror+file:/etc/apt/mirrors/debian.list|mirror+file:/etc/apt/mirrors/debian-security.list|mirror+file:///etc/apt/mirrors/debian.list|mirror+file:///etc/apt/mirrors/debian-security.list)
            file=${base#mirror+file:}; while [[ $file == //* ]]; do file=${file#/}; done
            plain_root_file "$file" || return 1
            local seen=no
            while IFS= read -r line || [[ -n $line ]]; do
                [[ -z $line || $line == \#* ]] && continue
                case $line in http://deb.debian.org/debian|https://deb.debian.org/debian|http://deb.debian.org/debian-security|https://deb.debian.org/debian-security|http://security.debian.org/debian-security|https://security.debian.org/debian-security) seen=yes ;; *) return 1 ;; esac
            done < "$file"
            [[ $seen == yes ]] || return 1 ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$suite"
}
check_sources() {
    local output line uri suite main=no security=no
    output=$(apt-get --print-uris update) || die 'Cannot inspect configured APT source URIs.'
    while IFS= read -r line; do
        [[ ${line:0:1} == "'" ]] || continue
        uri=${line#\'}; uri=${uri%%\'*}
        suite=$(validate_index_uri "$uri") || die "Unsupported repository URI: $uri"
        [[ $suite != trixie ]] || main=yes
        [[ $suite != trixie-security ]] || security=yes
    done <<< "$output"
    [[ $main == yes && $security == yes ]] || die 'Both official trixie and trixie-security sources are required.'
    local unsafe
    unsafe=$(apt-config dump | grep -Ei '(AllowUnauthenticated|AllowInsecureRepositories|AllowDowngradeToInsecureRepositories).*"(true|1)"' || true)
    [[ -z $unsafe ]] || die 'Insecure APT options are enabled; they were not changed.'
    if grep -Eiq '(^|[[:space:]])(trusted|allow-insecure)[[:space:]]*=[[:space:]]*(yes|true)|^[[:space:]]*(Trusted|Allow-Insecure):[[:space:]]*(yes|true)' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null; then
        die 'APT source bypasses trust verification; no source files were changed.'
    fi
}
check_origins() {
    local output
    output=$(apt-cache policy)
    awk '/^[[:space:]]*release / {
        if($0~/a=now([,[:space:]]|$)/)next
        if($0!~/o=Debian(-Security)?([,[:space:]]|$)/ || $0!~/n=trixie(-updates|-security)?([,[:space:]]|$)/) bad=1
        n++
    } END{exit(bad || n==0)}' <<< "$output" || die 'APT package indexes include unsupported origins or suites.'
}
apt_run() {
    DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 NEEDRESTART_MODE=l \
    apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
        -o Dpkg::Options::=--force-confold "$@"
}
strict_update() { check_sources; apt_run --error-on=any update; check_origins; }
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
    output=$(apt-cache policy "$pkg")
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
    printf '%s\n' '# Managed by next-vps-setup v1.0' '[Unit]' 'Description=next-vps-setup low-memory disk Swap (1 GiB)' \
        '' '[Swap]' "What=$SWAP_FILE" 'Priority=10' 'TimeoutSec=90s' \
        '' '[Install]' 'WantedBy=swap.target'
}
swap_sysctl_content() { printf '%s\n' '# Managed by next-vps-setup v1.0' 'vm.swappiness = 10'; }
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
        note 'MemTotal exceeds 1 GiB: disk Swap and memory settings were left unchanged.'
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
    note 'Prepared owned 1 GiB disk Swap, priority 10 and swappiness 10; boot persistence will be verified before success.'
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
# Managed by next-vps-setup v1.0
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
balloon_content() { printf '%s\n' '# Managed by next-vps-setup v1.0' 'blacklist virtio_balloon' 'install virtio_balloon /bin/false'; }
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
        note "WARNING: NTP ${S[ntp_status]}; keeping the existing system clock and continuing. No successful synchronization is claimed."
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
            note 'WARNING: Could not restart systemd-timedated; time synchronization is optional.'
        fi
    fi
    if ! systemctl enable --now "${S[ntp_unit]}"; then
        note "WARNING: Could not enable/start ${S[ntp_unit]}; time synchronization is optional."
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
    note "Saved stage ${S[phase]}; requesting normal reboot ($reason), count ${S[reboot_count]}/3."
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
    apt-get clean
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
    # Receipt is already durable: recovery after this point is cleanup-only.
    rm -- "$STATE_FILE" "$BASE/owner" "$WORKER"
    [[ ! -e $BASE/next-vps-setup.log ]] || rm -- "$BASE/next-vps-setup.log"
    rmdir -- "$BASE"
    [[ ! -e $entry ]] || rm -- "$entry"
    [[ ! -e $entry && ! -L $entry && ! -e $BASE && ! -e $UNIT_FILE ]] || die 'Cleanup incomplete; retained receipt allows cleanup recovery.'
    S[phase]='done'; S[result_status]=complete; S[failed]=no
    write_state_to "$RESULT"
    note "COMPLETE: kernel ${S[target_kernel]}, SSH ${S[ssh_port]}, Asia/Kuala_Lumpur, Fail2ban 5/600/-1, Swap ${S[swap_status]}, NTP ${S[ntp_status]:-not-recorded}. Receipt: $RESULT"
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
    printf 'FAILED: stage=%s; no success declared. Inspect %s/next-vps-setup.log and journalctl -u %s.\n' "${S[phase]:-unknown}" "$BASE" "$UNIT" >&2
    if [[ -d $BASE && -n ${S[phase]:-} ]]; then S[failed]=yes; save_state || true; fi
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
        note "Stage ${S[phase]}; boot $(boot_id)."
        case ${S[phase]} in
            swap) phase_swap ;; update) phase_update ;; configure) phase_configure ;; kernel) phase_kernel ;;
            balloon) phase_balloon ;; final) phase_final ;;
            cleanup) cleanup_success; return 0 ;; "done") return 0 ;;
            *) die 'Unknown stage.' ;;
        esac
    done
}
print_status() {
    printf 'Phase: %s\nResult: %s\nFailed: %s\nHost: %s\nSSH port: %s\nTarget kernel: %s\nReboots: %s/3\nSwap: %s (%s)\n' "${S[phase]}" "${S[result_status]}" "${S[failed]}" "${S[hostname]}" "${S[ssh_port]}" "${S[target_kernel]}" "${S[reboot_count]}" "${S[swap_status]}" "${S[swap_policy]}"
    printf 'NTP status: %s\n' "${S[ntp_status]:-not-recorded}"
    if [[ ${S[failed]} == yes ]]; then
        printf '%s\n' '任务已失败停止；Result: running 仅表示尚未完成，不代表后台仍在执行。'
    elif [[ ${S[ntp_status]:-not-recorded} == unsynchronized || ${S[ntp_status]:-not-recorded} == unavailable ]]; then
        printf '%s\n' '警告：NTP 未通过同步检查，沿用系统当前时间；这不会阻止其他步骤完成。'
    fi
}
launch_worker() {
    plain_root_file "$UNIT_FILE" && cmp -s "$UNIT_FILE" <(unit_content) || die 'Temporary service identity differs; it was not started.'
    systemctl daemon-reload || die 'Cannot reload the initialization service definition.'
    [[ $(systemctl show "$UNIT" -p FragmentPath --value) == "$UNIT_FILE" && -z $(systemctl show "$UNIT" -p DropInPaths --value) ]] || die 'Merged initialization service definition has an unexpected source or overrides; it was not started.'
    systemctl enable "$UNIT" || die 'Cannot enable initialization after reboot.'
    systemctl reset-failed "$UNIT" || die 'Cannot reset the initialization service failure.'
    flock -u 9 || die 'Cannot release the initialization handoff lock.'
    exec 9<&- || die 'Cannot close the initialization handoff lock.'
    systemctl start --no-block "$UNIT" || die 'Cannot submit the initialization start request.'
    printf '后台启动请求已提交。必要时会自动重启并续行，SSH 需要手动重新连接。\n首次断线后可先等待约 5–10 分钟再连接查询；这不是完成时限。\nNTP 无法同步时会警告并继续，完成摘要会记录 ntp_status。\n运行日志（成功后会清理）：\n  tail -f %s/next-vps-setup.log\n完成摘要：\n  cat %s\n只有有效摘要为 done / complete / failed=no 才表示全部必需步骤完成。\n' "$BASE" "$RESULT"
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
    printf '%s\n' '时间同步为尽力配置：不可用时会警告并继续，完成摘要会如实记录 NTP 状态。'
    printf '请输入这台 VPS 的机器名: '; IFS= read -r name
    validate_hostname "$name" || die 'Invalid hostname.'
    printf '请输入当前 SSH 端口（只核验，不修改）: '; IFS= read -r port
    validate_port "$port" || die 'Invalid SSH port.'
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
    save_state
    publish_config "$UNIT_FILE" "$(unit_content)"
    launch_worker
}

main() {
    local mode=${1:-start} entry
    (( $# <= 1 )) || die 'Use no arguments, --status, or --resume.'
    case $mode in start|--status|--resume|--worker) ;; --help) printf '%s\n' "next-vps-setup v$VERSION" 'Run from /root as root: bash /root/next-vps-setup.sh [--status|--resume]'; return 0 ;; *) die 'Unknown argument.' ;; esac
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
            [[ $(file_sha "$entry") == "${S[worker_sha]}" ]] || die 'Resume requires the same script version and payload.'
            if [[ ${S[phase]} == cleanup ]]; then prepare_cleanup_recovery "$entry"; return 0; fi
            verify_task_files
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
        if [[ ${S[result_status]} == complete ]]; then printf '%s\n' 'Already completed; no installation was repeated.'; return 0; fi
        if [[ $mode == --resume ]]; then prepare_cleanup_recovery "$entry"; return 0; fi
        die 'Cleanup was interrupted after its durable receipt. Retain this receipt and inspect remaining task files before cleanup recovery.'
    fi
    [[ $mode == start ]] || die 'No existing task or receipt.'
    [[ $0 == /* && ! -L $0 && -f $0 ]] || die 'Use bash followed by an absolute regular file under /root.'
    initialize_task "$entry"
}
main "$@"
