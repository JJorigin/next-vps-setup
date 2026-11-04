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
