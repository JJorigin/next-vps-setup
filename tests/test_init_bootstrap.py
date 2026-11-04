"""Rootless initialization bootstrap fault tests; delivery main is never run.

Only function definitions are copied into an isolated fixture. System-changing
commands are denied; initialize_task receives a real PTY and controlled input.
Every writable path belongs to TemporaryDirectory, never /root or /var/lib.
"""

from __future__ import annotations

import os
from pathlib import Path
import pty
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "next-vps-setup.sh"
TASK = "11111111-1111-4111-8111-111111111111"
BOOT = "22222222-2222-4222-8222-222222222222"


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Linux/WSL Bash")
class InitBootstrapTests(unittest.TestCase):
    def setUp(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("rootless temporary-directory tests only")
        self.tmp = tempfile.TemporaryDirectory(prefix="next-init-bootstrap-", dir="/tmp")
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.danger_log = self.root / "forbidden.log"
        self.calls = self.root / "calls.log"
        self.task = self.root / "task"
        self.state = self.task / "state.tsv"
        self.result = self.root / "result.tsv"
        self.entry = self.root / "uploaded.sh"
        self.entry.write_text("#!/bin/bash\n# identical isolated payload\n")
        self.library = self.root / "init-functions.sh"
        source = SCRIPT.read_text(encoding="utf-8")
        start = source.index("\ndie() {") + 1
        stop = source.rindex('\nmain "$@"')
        self.library.write_text(source[start:stop], encoding="utf-8")
        for name in (
            "apt", "apt-get", "apt-cache", "dpkg", "dpkg-query", "systemctl",
            "systemd-run", "reboot", "shutdown", "poweroff", "update-initramfs",
            "update-grub", "grub-install", "modprobe", "swapon", "swapoff",
            "sysctl", "mount", "umount", "hostnamectl", "timedatectl",
            "fail2ban-client", "install",
        ):
            path = self.bin / name
            path.write_text('#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$DANGER_LOG"\nexit 97\n')
            path.chmod(0o700)

    def tearDown(self) -> None:
        if self.danger_log.exists():
            self.fail("a forbidden host command was attempted:\n" + self.danger_log.read_text())

    def run_shell(self, body: str, *, terminal: bool = False, check: bool = True) -> subprocess.CompletedProcess[str]:
        bootstrap = r'''
set -Eeuo pipefail
source "$INIT_LIBRARY"
declare -A S=()
BASE=$FIXTURE_ROOT/task
STATE_FILE=$BASE/state.tsv
WORKER=$BASE/worker.sh
RESULT=$FIXTURE_ROOT/result.tsv
UNIT_FILE=$FIXTURE_ROOT/unit.service
UNIT=fixture-init.service
JAIL=$FIXTURE_ROOT/jail.local
BALLOON_CONF=$FIXTURE_ROOT/balloon.conf
VERSION=fixture
IN_REBOOT=no
BOOTSTRAP_BASE_ID= BOOTSTRAP_TEMP= BOOTSTRAP_TEMP_ID=
stat() {
    if [[ ${1:-} == -c && ${2:-} == %u && ${!#} == "$FIXTURE_ROOT"* ]]; then printf '0\n'
    else command stat "$@"; fi
}
cat() {
    case ${1:-} in
        /etc/machine-id) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
        /proc/sys/kernel/random/uuid) printf '11111111-1111-4111-8111-111111111111\n' ;;
        *) /bin/cat "$@" ;;
    esac
}
uname() { [[ ${1:-} == -r ]] || return 94; printf '6.12.113+deb13-cloud-amd64\n'; }
safe_entry_path() { [[ $1 == /root/next-vps-setup.sh ]]; }
file_sha() {
    if [[ $1 == /root/next-vps-setup.sh ]]; then sha256sum -- "$FIXTURE_ROOT/uploaded.sh" | awk '{print $1}'
    else sha256sum -- "$1" | awk '{print $1}'; fi
}
file_identity() {
    if [[ $1 == /root/next-vps-setup.sh ]]; then stat -c '%d:%i' -- "$FIXTURE_ROOT/uploaded.sh"
    else stat -c '%d:%i' -- "$1"; fi
}
cp() {
    [[ $# == 3 && $1 == -- && $2 == /root/next-vps-setup.sh && $3 == "$BASE"/.bootstrap-worker.* ]] || return 95
    [[ -f $STATE_FILE && $(awk -F '\t' '$1=="task_id"{print $2}' "$STATE_FILE") == "${S[task_id]}" ]] || return 96
    /bin/cp -- "$FIXTURE_ROOT/uploaded.sh" "$3"
}
fresh_fail2ban_preflight() { :; }
check_ssh() { [[ $1 == 56789 ]]; }
check_sources() { :; }
check_resources() { :; }
installed() { [[ $1 == linux-image-6.12.113+deb13-cloud-amd64 ]]; }
dpkg-query() { printf 'Debian Kernel Team <debian-kernel@lists.debian.org>\n'; }
memtotal() { printf '2097152\n'; }
detect_ntp() { printf 'systemd-timesyncd.service\n'; }
boot_id() { printf '22222222-2222-4222-8222-222222222222\n'; }
ssh_policy_sha() { printf '%064d\n' 0; }
nv_ui_heading() { :; }
nv_ui_stopped() { printf 'STOP: %s\n' "$*" >&2; }
nv_ui_stage_name() { printf '%s' "$1"; }
publish_login_notice() { printf 'notice:%s\n' "$1" >> "$CALLS"; }
launch_worker() {
    [[ -f $STATE_FILE && -f $WORKER && -f $BASE/owner ]]
    [[ $(awk -F '\t' '$1=="failed"{print $2}' "$RESULT") == no ]]
    [[ $(awk -F '\t' '$1=="result_status"{print $2}' "$RESULT") == running ]]
    printf 'LAUNCH\n' >> "$CALLS"
}
'''
        env = os.environ.copy()
        env.update({
            "INIT_LIBRARY": str(self.library), "FIXTURE_ROOT": str(self.root),
            "DANGER_LOG": str(self.danger_log), "CALLS": str(self.calls),
            "LC_ALL": "C", "PATH": f"{self.bin}:/usr/bin:/bin",
        })
        args = ["bash", "-c", bootstrap + "\n" + body]
        if terminal:
            master, slave = pty.openpty()
            try:
                proc = subprocess.Popen(args, stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=self.root, text=True)
                os.close(slave)
                slave = -1
                os.write(master, b"fixture-vps\n56789\n")
                stdout, stderr = proc.communicate(timeout=20)
                result = subprocess.CompletedProcess(args, proc.returncode, stdout, stderr)
            finally:
                if slave >= 0:
                    os.close(slave)
                os.close(master)
        else:
            result = subprocess.run(args, env=env, cwd=self.root, text=True, capture_output=True, timeout=20)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def read_state(self, path: Path) -> dict[str, str]:
        return dict(line.split("\t", 1) for line in path.read_text().splitlines())

    def initialize(self, injection: str = "", *, check: bool = True) -> subprocess.CompletedProcess[str]:
        return self.run_shell(injection + "\ninitialize_task /root/next-vps-setup.sh\n", terminal=True, check=check)

    def resume(self, *, check: bool = True) -> subprocess.CompletedProcess[str]:
        return self.run_shell(r'''
if [[ -f $STATE_FILE ]]; then parse_state "$STATE_FILE"; else parse_state "$RESULT"; fi
prepare_bootstrap_recovery /root/next-vps-setup.sh
''', check=check)

    def test_interactive_bootstrap_publishes_verified_worker_and_pending_receipt(self) -> None:
        self.initialize()
        self.assertEqual((self.task / "worker.sh").read_bytes(), self.entry.read_bytes())
        self.assertEqual((self.task / "worker.sh").stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.task / "owner").read_text(), TASK + "\n")
        self.assertEqual(self.read_state(self.state), self.read_state(self.result))
        self.assertEqual(self.read_state(self.result)["phase"], "swap")
        self.assertEqual(self.calls.read_text(), "LAUNCH\n")

    def test_copy_failure_keeps_initial_state_without_partial_worker_and_resumes(self) -> None:
        proc = self.initialize('cp() { printf partial > "$3"; return 73; }', check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse((self.task / "worker.sh").exists())
        self.assertEqual(list(self.task.glob(".bootstrap-*")), [])
        self.assertFalse((self.root / "unit.service").exists())
        for path in (self.state, self.result):
            saved = self.read_state(path)
            self.assertEqual(saved["task_id"], TASK)
            self.assertEqual(saved["failed"], "yes")
            self.assertEqual(saved["result_status"], "running")
        self.assertEqual(self.calls.read_text(), "notice:failure\n")
        self.resume()
        self.assertEqual((self.task / "worker.sh").read_bytes(), self.entry.read_bytes())
        self.assertEqual(self.read_state(self.result)["failed"], "no")

    def test_mkdir_failure_records_initial_receipt_and_resumes_without_task_directory(self) -> None:
        proc = self.initialize("mkdir() { return 73; }", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.task.exists())
        self.assertEqual(self.read_state(self.result)["failed"], "yes")
        self.resume()
        self.assertTrue((self.task / "worker.sh").exists())

    def test_initial_state_failure_recovers_from_result_and_owned_directory(self) -> None:
        proc = self.initialize("save_state() { return 74; }", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue((self.task / "owner").exists())
        self.assertFalse(self.state.exists())
        self.assertFalse((self.task / "worker.sh").exists())
        self.assertEqual(self.read_state(self.result)["failed"], "yes")
        self.resume()
        self.assertTrue(self.state.exists())

    def test_owner_temporary_failure_removes_only_its_empty_directory(self) -> None:
        proc = self.initialize(r'''
mktemp() {
    [[ $1 != "$BASE"/.bootstrap-owner.* ]] || return 73
    command mktemp "$@"
}
''', check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.task.exists())
        self.resume()
        self.assertTrue((self.task / "owner").exists())

    def test_unit_failure_retains_full_worker_and_recovers(self) -> None:
        proc = self.initialize("publish_config() { return 75; }", check=False)
        self.assertNotEqual(proc.returncode, 0)
        worker = self.task / "worker.sh"
        before = (worker.read_bytes(), worker.stat().st_ino)
        self.resume()
        self.assertEqual((worker.read_bytes(), worker.stat().st_ino), before)

    def test_recovery_refuses_unknown_owner_and_preserves_state_identity(self) -> None:
        self.initialize("cp() { return 73; }", check=False)
        owner = self.task / "owner"
        original = owner.read_bytes()
        before = (self.state.read_bytes(), self.state.stat().st_ino)
        for contents in (None, b"33333333-3333-4333-8333-333333333333\n"):
            with self.subTest(contents=contents):
                if owner.exists():
                    owner.unlink()
                if contents is not None:
                    owner.write_bytes(contents)
                self.assertNotEqual(self.resume(check=False).returncode, 0)
                self.assertEqual((self.state.read_bytes(), self.state.stat().st_ino), before)
                if contents is None:
                    self.assertFalse(owner.exists())
                else:
                    self.assertEqual(owner.read_bytes(), contents)
        owner.write_bytes(original)

    def test_recovery_refuses_unknown_file_and_changed_worker(self) -> None:
        self.initialize("cp() { return 73; }", check=False)
        unknown = self.task / "unknown-user-file"
        unknown.write_text("must remain")
        self.assertNotEqual(self.resume(check=False).returncode, 0)
        self.assertEqual(unknown.read_text(), "must remain")
        self.assertFalse((self.task / "worker.sh").exists())
        unknown.unlink()
        worker = self.task / "worker.sh"
        worker.write_text("changed worker must remain")
        self.assertNotEqual(self.resume(check=False).returncode, 0)
        self.assertEqual(worker.read_text(), "changed worker must remain")

    def test_state_parent_requires_trusted_ancestors_before_locking(self) -> None:
        parent = self.root / "state-parent"
        parent.mkdir(mode=0o755)
        child = parent / "child"
        child.mkdir(mode=0o755)
        # Only the fixture's /tmp ancestor is modeled as a trusted system
        # directory. No host permissions are changed by this rootless test.
        metadata = r'''
stat() {
    if [[ ${1:-} == -c && ${2:-} == %a && ${!#} == /tmp ]]; then printf '755\n'
    elif [[ ${1:-} == -c && ${2:-} == %u && ${!#} == "$FIXTURE_ROOT"* ]]; then
        if [[ ${!#} == "${NONROOT_PATH:-}" ]]; then printf '12345\n'; else printf '0\n'; fi
    else command stat "$@"; fi
}
'''
        self.run_shell(metadata + '\nsafe_state_parent "$FIXTURE_ROOT/state-parent/child"\n')
        parent.chmod(0o777)
        self.assertNotEqual(self.run_shell(metadata + '\nsafe_state_parent "$FIXTURE_ROOT/state-parent/child"\n', check=False).returncode, 0)
        parent.chmod(0o755)
        self.assertNotEqual(self.run_shell(metadata + '\nNONROOT_PATH=$FIXTURE_ROOT/state-parent; safe_state_parent "$FIXTURE_ROOT/state-parent/child"\n', check=False).returncode, 0)
        alias = self.root / "parent-link"
        alias.symlink_to(parent, target_is_directory=True)
        self.assertNotEqual(self.run_shell(metadata + '\nsafe_state_parent "$FIXTURE_ROOT/parent-link/child"\n', check=False).returncode, 0)
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertLess(source.index("safe_state_parent /var/lib"), source.index("exec 9</var/lib"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
