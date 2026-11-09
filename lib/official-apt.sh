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
