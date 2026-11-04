"""Rootless official-APT-view tests. No downloads or package mutations.

Only apt-config dump, apt-cache policy and apt-get --print-uris update may use
the real APT binaries. Mutating apt-get calls are replaced by a recording stub.
All writable paths are TemporaryDirectory children; delivery main is not run.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
LIBRARY = PROJECT / "lib/official-apt.sh"
SCRIPTS = (PROJECT / "next-vps-setup.sh", PROJECT / "next-vps-kernel-update.sh")
BEGIN = "# BEGIN NEXT-VPS OFFICIAL APT VIEW"
END = "# END NEXT-VPS OFFICIAL APT VIEW"
TASK = "11111111-1111-4111-8111-111111111111"


class OfficialAptSourceTests(unittest.TestCase):
    def test_embedded_blocks_match_the_reviewed_library(self) -> None:
        expected = LIBRARY.read_text(encoding="utf-8").strip()
        for script in SCRIPTS:
            with self.subTest(script=script.name):
                source = script.read_text(encoding="utf-8")
                start = source.index(BEGIN)
                stop = source.index(END, start) + len(END)
                self.assertEqual(source[start:stop], expected)

    def test_all_package_queries_and_updates_use_the_private_view(self) -> None:
        for script in SCRIPTS:
            with self.subTest(script=script.name):
                source = script.read_text(encoding="utf-8")
                self.assertNotIn("$(apt-cache ", source)
                self.assertNotRegex(source, r"(?m)^\s+apt-get (?:clean|update|install|dist-upgrade)")
                self.assertIn("official_apt_recover_indexes", source)
                self.assertIn("official_apt_cleanup", source)


@unittest.skipUnless(
    os.name == "posix" and shutil.which("bash") and shutil.which("apt-config")
    and shutil.which("apt-cache") and shutil.which("apt-get"),
    "requires Linux/WSL with Bash and APT",
)
class OfficialAptViewTests(unittest.TestCase):
    def setUp(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("these tests must run as an ordinary user")
        self.tmp = tempfile.TemporaryDirectory(prefix="next-official-apt-", dir="/tmp")
        self.root = Path(self.tmp.name)
        self.root.chmod(0o755)
        self.addCleanup(self.tmp.cleanup)
        self.base = self.root / "task"
        self.view = Path(str(self.base) + "-apt")
        # Ubuntu WSL need not have Debian keys: a fixture keyring is sufficient
        # for config/URI preview tests, which never authenticate or download.
        self.keyring = self.root / "debian-archive-keyring.gpg"
        self.keyring.write_text("synthetic keyring; no download allowed\n")
        self.keyring.chmod(0o644)
        self.library = self.root / "official-apt-fixture.sh"
        self.library.write_text(LIBRARY.read_text().replace(
            "/usr/share/keyrings/debian-archive-keyring.gpg", str(self.keyring)
        ), encoding="utf-8")
        self.host = self.root / "host"
        self.host.mkdir()
        self.sentinel = self.root / "hook-executed"
        self.host_config = self.host / "host.conf"
        self.host_config.write_text(
            f'Dir::State::status "{self.host / "untrusted-status"}";\n'
            f'Dir::Etc::parts "{self.host}";\n'
            'Acquire::http::Proxy "http://third-party.invalid:8080";\n'
            f'DPkg::Pre-Install-Pkgs {{ "touch {self.sentinel}"; }};\n'
            'APT::Get::AllowUnauthenticated "true";\n',
            encoding="utf-8",
        )
        (self.host / "evil.conf").write_text(
            'Dir::Bin::dpkg "/not-the-real-dpkg";\n'
            'Binary::apt-get::APT::Get::AutomaticRemove "true";\n', encoding="utf-8",
        )
        self.host_before = {p.name: p.read_bytes() for p in self.host.iterdir()}

    def run_shell(self, body: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
        # Ownership is mapped only in the fixture's stat wrapper because a
        # rootless test cannot manufacture UID-0 files. Permissions and file
        # types are checked by the original production functions unchanged.
        bootstrap = r'''
set -Eeuo pipefail
source "$OFFICIAL_APT_LIBRARY"
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
declare -A S=([task_id]="$TASK_ID")
BASE=$FIXTURE_ROOT/task
stat() {
    if [[ ${1:-} == -c && ${2:-} == %u && ${!#} == "$FIXTURE_ROOT"* ]]; then printf '0\n'
    else command stat "$@"; fi
}
'''
        env = os.environ.copy()
        env.update({
            "OFFICIAL_APT_LIBRARY": str(self.library), "FIXTURE_ROOT": str(self.root),
            "TASK_ID": TASK, "LC_ALL": "C", "APT_CONFIG": str(self.host_config),
            "http_proxy": "http://third-party.invalid:8080",
            "HTTPS_PROXY": "http://third-party.invalid:8080",
        })
        proc = subprocess.run(
            ["bash", "-c", bootstrap + "\n" + body], env=env, cwd=self.root,
            text=True, capture_output=True, timeout=30,
        )
        self.assertFalse(self.sentinel.exists(), "a host-config APT hook executed")
        self.assertEqual({p.name: p.read_bytes() for p in self.host.iterdir()}, self.host_before)
        if check:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def test_prepare_is_idempotent_and_keeps_download_sandbox(self) -> None:
        self.run_shell("official_apt_prepare; official_apt_prepare")
        self.assertEqual(self.view.stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.view / "owner").read_text(), TASK + "\n")
        self.assertEqual((self.view / "official.sources").stat().st_mode & 0o777, 0o644)
        config = (self.view / "apt.conf").read_text()
        self.assertIn('APT::Sandbox::User "_apt";', config)
        self.assertIn('APT::Install-Recommends "false";', config)
        self.assertIn('Acquire::PDiffs "false";', config)

    def test_effective_config_ignores_host_hooks_proxy_pins_and_dir_overrides(self) -> None:
        proc = self.run_shell("official_apt_prepare; official_apt_exec apt-config dump")
        dump = proc.stdout
        expected = {
            "Dir::Etc::main": self.view / "empty.conf",
            "Dir::Etc::parts": self.view / "parts",
            "Dir::Etc::sourcelist": self.view / "official.sources",
            "Dir::Etc::sourceparts": self.view / "sourceparts",
            "Dir::Etc::preferences": self.view / "preferences",
            "Dir::Etc::preferencesparts": self.view / "preferencesparts",
            "Dir::State::lists": self.view / "lists",
        }
        for key, value in expected.items():
            self.assertIn(f'{key} "{value}";', dump)
        self.assertIn('Dir::State::status "/var/lib/dpkg/status";', dump)
        self.assertIn('Dir::State::extended_states "/var/lib/apt/extended_states";', dump)
        self.assertIn('Dir::Cache::archives "/var/cache/apt/archives";', dump)
        self.assertIn('Dir::Bin::dpkg "/usr/bin/dpkg";', dump)
        self.assertIn('APT::Get::AutomaticRemove "false";', dump)
        self.assertIn('APT::Get::AllowUnauthenticated "false";', dump)
        self.assertIn('Acquire::AllowInsecureRepositories "false";', dump)
        self.assertIn('APT::Sandbox::User "_apt";', dump)
        self.assertNotIn("third-party.invalid", dump)
        self.assertNotIn("hook-executed", dump)
        self.assertNotIn("untrusted-status", dump)
        self.assertNotIn("not-the-real-dpkg", dump)

    def test_print_uris_has_only_official_debian_suites_without_network(self) -> None:
        proc = self.run_shell("official_apt_prepare; official_apt_exec apt-get --print-uris update")
        uris = re.findall(r"^'([^']+)'", proc.stdout, re.MULTILINE)
        self.assertTrue(uris, proc.stdout + proc.stderr)
        for uri in uris:
            self.assertRegex(uri, r"^http://(?:deb\.debian\.org/debian/dists/trixie(?:-updates)?/|security\.debian\.org/debian-security/dists/trixie-security/)")
        source = (self.view / "official.sources").read_text()
        self.assertEqual(source.count(f"Signed-By: {self.keyring}"), 2)
        self.assertNotIn("third-party", source)

    def test_host_override_environment_is_not_inherited_by_apt(self) -> None:
        proc = self.run_shell(r'''
official_apt_prepare
export DPKG_ROOT=/wrong DPKG_ADMINDIR=/wrong DPKG_FORCE=all DPKG_FRONTEND_LOCKED=1
official_apt_exec /usr/bin/env
''')
        self.assertIn(f"APT_CONFIG={self.view}/apt.conf", proc.stdout)
        for key in ("DPKG_ROOT=", "DPKG_ADMINDIR=", "DPKG_FORCE=", "DPKG_FRONTEND_LOCKED=", "http_proxy=", "HTTPS_PROXY="):
            self.assertNotIn(key, proc.stdout)

    def test_changed_source_or_config_is_rejected_without_overwrite(self) -> None:
        for name in ("apt.conf", "official.sources", "preferences", "auth.conf"):
            with self.subTest(file=name):
                self.run_shell("official_apt_prepare")
                path = self.view / name
                original = path.read_bytes()
                path.write_text("changed\n")
                proc = self.run_shell("official_apt_prepare", check=False)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(path.read_text(), "changed\n")
                path.write_bytes(original)

    def test_wrong_task_owner_is_rejected(self) -> None:
        self.run_shell("official_apt_prepare")
        (self.view / "owner").write_text("22222222-2222-4222-8222-222222222222\n")
        self.assertNotEqual(self.run_shell("official_apt_prepare", check=False).returncode, 0)

    def test_missing_owner_does_not_adopt_existing_data(self) -> None:
        self.run_shell("official_apt_prepare")
        (self.view / "owner").unlink()
        proc = self.run_shell("official_apt_prepare", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse((self.view / "owner").exists())

    def test_symlink_and_writable_private_config_are_rejected(self) -> None:
        self.run_shell("official_apt_prepare")
        source = self.view / "official.sources"
        original = source.read_bytes()
        source.unlink()
        source.symlink_to(self.host_config)
        self.assertNotEqual(self.run_shell("official_apt_prepare", check=False).returncode, 0)
        source.unlink()
        source.write_bytes(original)
        source.chmod(0o666)
        self.assertNotEqual(self.run_shell("official_apt_prepare", check=False).returncode, 0)

    def test_unexpected_or_unsafe_index_entries_block_cleanup(self) -> None:
        self.run_shell("official_apt_prepare")
        unknown = self.view / "lists" / "third-party.invalid_Packages"
        unknown.write_text("unknown\n")
        proc = self.run_shell("official_apt_cleanup", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue((self.view / "owner").exists())
        self.assertEqual(unknown.read_text(), "unknown\n")

    def test_index_symlink_never_deletes_its_external_target(self) -> None:
        self.run_shell("official_apt_prepare")
        alias = self.view / "lists" / "deb.debian.org_debian_dists_trixie_InRelease"
        alias.symlink_to(self.host_config)
        self.assertNotEqual(self.run_shell("official_apt_cleanup", check=False).returncode, 0)
        self.assertTrue(alias.is_symlink())

    def test_unknown_configuration_part_blocks_apt_before_execution(self) -> None:
        self.run_shell("official_apt_prepare")
        injected = self.view / "parts" / "evil.conf"
        injected.write_text('DPkg::Pre-Invoke { "false"; };\n')
        proc = self.run_shell("apt_cache policy", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("更新暂存目录出现未知内容或权限变化", proc.stderr)

    def test_known_indexes_and_partial_files_are_cleaned_without_touching_host(self) -> None:
        self.run_shell("official_apt_prepare")
        for name in (
            "deb.debian.org_debian_dists_trixie_InRelease",
            "security.debian.org_debian-security_dists_trixie-security_InRelease",
            "partial/deb.debian.org_debian_dists_trixie_main_binary-amd64_Packages.lz4",
        ):
            (self.view / "lists" / name).write_text("synthetic index\n")
        self.run_shell("official_apt_prepare; official_apt_cleanup")
        self.assertFalse(self.view.exists())

    def test_private_root_mode_must_allow_sandbox_traversal(self) -> None:
        self.run_shell("official_apt_prepare")
        self.view.chmod(0o700)
        self.assertNotEqual(self.run_shell("official_apt_prepare", check=False).returncode, 0)

    def test_keyring_writable_or_unreadable_to_sandbox_is_rejected(self) -> None:
        for mode in (0o666, 0o640):
            with self.subTest(mode=oct(mode)):
                self.keyring.chmod(mode)
                self.assertNotEqual(self.run_shell("check_sources", check=False).returncode, 0)
        self.keyring.chmod(0o644)

    def test_partial_cleanup_failure_preserves_owner_and_can_rebuild(self) -> None:
        self.run_shell("official_apt_prepare")
        proc = self.run_shell(r'''
rm() {
    if [[ ${!#} == */official.sources ]]; then return 43; fi
    command rm "$@"
}
if official_apt_cleanup; then exit 96; fi
[[ -f $(official_apt_root)/owner ]]
unset -f rm
official_apt_prepare
''')
        self.assertEqual(proc.returncode, 0)
        self.assertEqual((self.view / "owner").read_text(), TASK + "\n")
        self.assertTrue((self.view / "apt.conf").exists())

    def test_wrappers_use_only_private_config_and_do_not_invoke_host_apt(self) -> None:
        bindir = self.root / "bin"
        bindir.mkdir()
        for tool in ("apt-get", "apt-cache"):
            stub = bindir / tool
            stub.write_text(
                '#!/bin/bash\nset -eu\nprintf "%s\\n" "$APT_CONFIG" "$0 $*"\n',
                encoding="utf-8",
            )
            stub.chmod(0o700)
        proc = self.run_shell(r'''
export PATH="$FIXTURE_ROOT/bin:/usr/bin:/bin"
apt_run -s --no-remove install synthetic-package
apt_cache policy synthetic-package
''')
        self.assertEqual(proc.stdout.count(str(self.view / "apt.conf")), 2)
        self.assertIn("-s --no-remove install synthetic-package", proc.stdout)
        self.assertIn("policy synthetic-package", proc.stdout)

    def test_recovery_refreshes_missing_indexes_only(self) -> None:
        self.run_shell(r'''
official_apt_prepare
strict_update() { printf 'REFRESH\n'; }
official_apt_recover_indexes
''')
        for name in (
            "deb.debian.org_debian_dists_trixie_InRelease",
            "security.debian.org_debian-security_dists_trixie-security_InRelease",
            "deb.debian.org_debian_dists_trixie_main_binary-amd64_Packages.lz4",
            "security.debian.org_debian-security_dists_trixie-security_main_binary-amd64_Packages.lz4",
        ):
            (self.view / "lists" / name).write_text("synthetic index\n")
        proc = self.run_shell(r'''
strict_update() { printf 'SHOULD_NOT_REFRESH\n'; return 91; }
official_apt_recover_indexes
''')
        self.assertNotIn("SHOULD_NOT_REFRESH", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
