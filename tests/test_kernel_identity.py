"""Read-only amd64 image identity tests and the actual in-transaction guard.

All boot images and package records are synthetic temporary files. The real
delivery main is never run; package-changing commands are deny-by-default.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
LIBRARY = PROJECT / "lib/kernel-identity.sh"
UPDATER = PROJECT / "next-vps-kernel-update.sh"
ABI = "6.12.115+deb13.1-cloud-amd64"
TARGET = "linux-image-" + ABI
META = "linux-image-cloud-amd64"
VERSION = "6.12.115-2"
OLD = "linux-image-6.12.113+deb13-cloud-amd64"
OLD_VERSION = "6.12.113-1"
BUILD = "#1 SMP PREEMPT_DYNAMIC Debian 6.12.115-2 (2026-10-22)"
OLD_BUILD = "#1 SMP PREEMPT_DYNAMIC Debian 6.12.115-1 (2026-10-21)"
BEFORE = "11111111-1111-4111-8111-111111111111"
AFTER = "22222222-2222-4222-8222-222222222222"


def image_bytes(
    banner: bytes | None = None, *, setup_sects: int = 4,
    pointer: int = 0x100, terminate: bool = True,
) -> bytearray:
    data = bytearray(4096)
    data[0x1f1] = setup_sects
    data[0x1fe:0x200] = b"\x55\xaa"
    data[0x202:0x206] = b"HdrS"
    struct.pack_into("<H", data, 0x206, 0x20f)
    struct.pack_into("<H", data, 0x20e, pointer)
    if banner is None:
        banner = f"{ABI} (debian-kernel@lists.debian.org) {BUILD}".encode("ascii")
    offset = 0x200 + pointer
    if 0 <= offset < len(data):
        if terminate:
            data[offset:offset + len(banner) + 1] = banner + b"\0"
        else:
            data[offset:] = b"X" * (len(data) - offset)
    return data


class EmbeddedKernelIdentityTests(unittest.TestCase):
    def test_both_downloads_embed_exact_reviewed_identity_helper(self) -> None:
        expected = LIBRARY.read_text(encoding="utf-8").strip()
        begin = "# BEGIN EMBEDDED kernel-identity\n"
        end = "# END EMBEDDED kernel-identity"
        for name in ("next-vps-setup.sh", "next-vps-kernel-update.sh"):
            with self.subTest(script=name):
                source = (PROJECT / name).read_text(encoding="utf-8")
                self.assertEqual(source.split(begin, 1)[1].split(end, 1)[0].strip(), expected)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash") and Path("/usr/bin/python3").exists(), "requires Linux/WSL Bash and system Python")
class KernelImageIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("rootless fixture only")
        self.tmp = tempfile.TemporaryDirectory(prefix="next-kernel-identity-", dir="/tmp")
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.image = self.root / "vmlinuz"
        self.image.write_bytes(image_bytes())
        self.image.chmod(0o600)

    def check_image(self, *, path: Path | None = None, release: str = ABI, build: str = BUILD) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-c", 'set -Eeuo pipefail; source "$1"; nv_kernel_image_matches "$2" "$3" "$4"',
             "test", str(LIBRARY), str(path or self.image), release, build],
            text=True, capture_output=True, timeout=10,
        )

    def test_current_official_image_banner_matches_full_running_build(self) -> None:
        proc = self.check_image()
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_same_abi_old_running_build_is_rejected(self) -> None:
        proc = self.check_image(build=OLD_BUILD)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("running kernel build differs", proc.stderr)

    def test_wrong_running_abi_is_rejected(self) -> None:
        self.assertNotEqual(self.check_image(release="6.12.113+deb13-cloud-amd64").returncode, 0)

    def test_invalid_magic_protocol_and_short_headers_are_rejected(self) -> None:
        for fault in ("boot_flag", "HdrS", "protocol", "short"):
            with self.subTest(fault=fault):
                data = image_bytes()
                if fault == "boot_flag":
                    data[0x1fe] = 0
                elif fault == "HdrS":
                    data[0x202] = 0
                elif fault == "protocol":
                    struct.pack_into("<H", data, 0x206, 0x1ff)
                else:
                    data = data[:0x20f]
                self.image.write_bytes(data)
                self.assertNotEqual(self.check_image().returncode, 0)

    def test_pointer_outside_header_setup_or_file_is_rejected(self) -> None:
        for pointer in (0, 0xf, 4 * 512, 0xffff):
            with self.subTest(pointer=pointer):
                data = image_bytes()
                struct.pack_into("<H", data, 0x20e, pointer)
                self.image.write_bytes(data)
                self.assertNotEqual(self.check_image().returncode, 0)

    def test_setup_sects_zero_uses_legacy_four_sector_size(self) -> None:
        self.image.write_bytes(image_bytes(setup_sects=0))
        self.assertEqual(self.check_image().returncode, 0)

    def test_unterminated_or_control_character_banners_are_rejected(self) -> None:
        bad_banners = [b"", b"bad\nbanner", b"bad\x1bbanner", b"bad\xffbanner"]
        for banner in bad_banners:
            with self.subTest(banner=banner):
                self.image.write_bytes(image_bytes(banner))
                self.assertNotEqual(self.check_image().returncode, 0)
        self.image.write_bytes(image_bytes(terminate=False))
        self.assertNotEqual(self.check_image().returncode, 0)

    def test_symlink_and_writable_image_are_rejected(self) -> None:
        alias = self.root / "image-link"
        alias.symlink_to(self.image)
        self.assertNotEqual(self.check_image(path=alias).returncode, 0)
        for mode in (0o620, 0o602, 0o666):
            with self.subTest(mode=oct(mode)):
                self.image.chmod(mode)
                self.assertNotEqual(self.check_image().returncode, 0)

    def test_truncated_banner_at_file_boundary_is_rejected(self) -> None:
        data = image_bytes()
        self.image.write_bytes(data[:0x310])
        self.assertNotEqual(self.check_image().returncode, 0)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash") and shutil.which("dpkg") and Path("/usr/bin/python3").exists(), "requires Linux/WSL Bash, system Python and dpkg version comparison")
class ActualAptGuardIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("rootless fixture only")
        self.tmp = tempfile.TemporaryDirectory(prefix="next-real-guard-identity-", dir="/tmp")
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.task = self.root / "task"
        self.task.mkdir(mode=0o700)
        self.boot = self.root / "boot"
        self.boot.mkdir()
        self.image = self.boot / f"vmlinuz-{ABI}"
        self.image.write_bytes(image_bytes())
        self.image.chmod(0o600)
        self.manifest = self.task / "purge.tsv"
        self.manifest.write_text(f"{OLD}\t{OLD_VERSION}\n")
        self.manifest.chmod(0o600)
        self.approved = self.root / "protocol-approved"
        self.dpkg_calls = self.root / "dpkg-called"
        self.dpkg_queries = self.root / "query-called"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.deny_log = self.root / "forbidden.log"
        for name in ("apt", "apt-get", "apt-cache", "apt-mark", "systemctl", "reboot", "shutdown", "poweroff", "update-initramfs", "update-grub", "grub-install", "modprobe", "swapon", "swapoff", "sysctl", "mount", "umount", "hostnamectl", "timedatectl", "fail2ban-client", "install"):
            path = self.bin / name
            path.write_text('#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$DENY_LOG"\nexit 97\n')
            path.chmod(0o700)
        self.real_dpkg = shutil.which("dpkg")

    def tearDown(self) -> None:
        self.assertFalse(self.deny_log.exists(), self.deny_log.read_text() if self.deny_log.exists() else "")
        self.assertFalse(self.dpkg_calls.exists(), "no real package operation is allowed")

    def run_guard(self, build: str) -> subprocess.CompletedProcess[str]:
        version = None
        for line in UPDATER.read_text(encoding="utf-8").splitlines():
            if line.startswith("VERSION="):
                version = line.split("=", 1)[1]
                break
        self.assertIsNotNone(version)
        state = {
            "format": "1", "version": version, "task_id": BEFORE,
            "machine_id": "a" * 32, "phase": "purge", "failed": "no",
            "result_status": "running", "meta": META, "meta_version": VERSION,
            "target_pkg": TARGET, "target_abi": ABI, "target_version": VERSION,
            "boot_before": BEFORE, "verified_boot": "-", "reboots": "1",
            "entry": "/root/next-vps-kernel-update.sh", "entry_id": "2049:123",
            "script_sha": hashlib.sha256(UPDATER.read_bytes()).hexdigest(),
            "config_sha": "b" * 64, "ssh_sha": "c" * 64, "swap_sha": "d" * 64,
            "swappiness": "10", "services": "ssh.service,fail2ban.service",
            "balloon": "module", "removed": "-", "verified_at": "0",
            "purge_sha": hashlib.sha256(self.manifest.read_bytes()).hexdigest(),
        }
        state_path = self.task / "state.tsv"
        state_path.write_text("".join(f"{key}\t{value}\n" for key, value in state.items()))
        state_path.chmod(0o600)
        body = r'''
set -Eeuo pipefail
source "$UPDATER"
WORKER=$0
BASE=$FIXTURE_ROOT/task
STATE=$BASE/state.tsv
PURGE_MANIFEST=$BASE/purge.tsv
BOOT_DIR=$FIXTURE_ROOT/boot
APT_HOOK_INFO_FD=0
sha() {
    if [[ $1 == "$WORKER" ]]; then sha256sum -- "$UPDATER" | awk '{print $1}'
    else sha256sum -- "$1" | awk '{print $1}'; fi
}
stat() {
    if [[ ${1:-} == -c && ${2:-} == %u && ${!#} == "$FIXTURE_ROOT"* ]]; then printf '0\n'
    else command stat "$@"; fi
}
cat() {
    if [[ ${1:-} == /etc/machine-id ]]; then printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    else /bin/cat "$@"; fi
}
boot_id() { printf '22222222-2222-4222-8222-222222222222\n'; }
uname() {
    case ${1:-} in
        -r) printf '%s\n' "$FIXTURE_ABI" ;;
        -v) printf '%s\n' "$FIXTURE_BUILD" ;;
        *) return 96 ;;
    esac
}
dpkg-query() {
    printf '%s\n' "$*" >> "$QUERY_LOG"
    local pkg=${!#}
    case "$*" in
        *'${db:Status-Status}'*) printf 'installed' ;;
        *'${Version}'*)
            if [[ $pkg == "$FIXTURE_OLD" ]]; then printf '%s' "$FIXTURE_OLD_VERSION"
            else printf '%s' "$FIXTURE_VERSION"; fi ;;
        *'${Depends}'*) printf '%s (= %s)' "$FIXTURE_TARGET" "$FIXTURE_VERSION" ;;
        *'${Maintainer}'*) printf 'Debian Kernel Team <debian-kernel@lists.debian.org>' ;;
        *) return 96 ;;
    esac
}
dpkg() {
    if [[ ${1:-} == --compare-versions && $# == 4 ]]; then "$REAL_DPKG" "$@"; return; fi
    printf '%s\n' "$*" >> "$DPKG_LOG"; return 97
}
# Keep the real validation function. A downstream marker proves the whole
# in-transaction identity gate was passed before approving the protocol.
eval "$(declare -f validate_purge_protocol | sed '1s/validate_purge_protocol/real_validate_purge_protocol/')"
validate_purge_protocol() {
    real_validate_purge_protocol "$@" || return
    printf 'approved\n' > "$APPROVED_LOG"
}
apt_guard
'''
        env = os.environ.copy()
        env.update({
            "UPDATER": str(UPDATER), "FIXTURE_ROOT": str(self.root),
            "FIXTURE_ABI": ABI, "FIXTURE_BUILD": build, "FIXTURE_VERSION": VERSION,
            "FIXTURE_TARGET": TARGET, "FIXTURE_OLD": OLD, "FIXTURE_OLD_VERSION": OLD_VERSION,
            "QUERY_LOG": str(self.dpkg_queries), "DPKG_LOG": str(self.dpkg_calls),
            "APPROVED_LOG": str(self.approved), "DENY_LOG": str(self.deny_log),
            "REAL_DPKG": self.real_dpkg, "PATH": f"{self.bin}:/usr/bin:/bin", "LC_ALL": "C",
        })
        protocol = f"VERSION 2\n\n{OLD} {OLD_VERSION} > - **REMOVE**\n"
        return subprocess.run(
            ["bash", "-c", body, "isolated-apt-guard"], env=env, cwd=self.root,
            input=protocol, text=True, capture_output=True, timeout=15,
        )

    def test_actual_guard_accepts_matching_target_build_and_exact_protocol(self) -> None:
        proc = self.run_guard(BUILD)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.approved.read_text(), "approved\n")
        self.assertTrue(self.dpkg_queries.exists())

    def test_actual_guard_rejects_old_same_abi_build_before_package_queries_or_protocol_approval(self) -> None:
        proc = self.run_guard(OLD_BUILD)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("cannot confirm the running target kernel build", proc.stderr)
        self.assertFalse(self.approved.exists())
        self.assertFalse(self.dpkg_queries.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
