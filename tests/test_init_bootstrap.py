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
KIB_PER_GIB=1048576
BYTES_PER_GIB=1073741824
SWAP_RESERVE_KIB=$KIB_PER_GIB
SWAP_PREPARE_KIB=16384
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
safe_state_parent() { [[ $1 == "$FIXTURE_ROOT" || $1 == "$FIXTURE_ROOT"/* ]]; }
file_sha() {
    if [[ $1 == /root/next-vps-setup.sh ]]; then sha256sum -- "$FIXTURE_ROOT/uploaded.sh" | awk '{print $1}'
    else sha256sum -- "$1" | awk '{print $1}'; fi
}
file_identity() {
    if [[ $1 == /root/next-vps-setup.sh ]]; then stat -c '%d:%i' -- "$FIXTURE_ROOT/uploaded.sh"
    else stat -c '%d:%i' -- "$1"; fi
}
mv() {
    if [[ $# == 6 && $1 == -T && $2 == --no-copy && $3 == --update=none-fail && $4 == -- ]]; then
        [[ $5 == "$FIXTURE_ROOT"/* && $6 == "$FIXTURE_ROOT"/* && ! -e $6 && ! -L $6 ]] || return 96
        command mv -T -- "$5" "$6"
    else command mv "$@"; fi
}
cp() {
    [[ $# == 3 && $1 == -- && $2 == /root/next-vps-setup.sh && $3 == "$BASE"/.bootstrap-worker.* ]] || return 95
    [[ -f $STATE_FILE && $(awk -F '\t' '$1=="task_id"{print $2}' "$STATE_FILE") == "${S[task_id]}" ]] || return 96
    /bin/cp -- "$FIXTURE_ROOT/uploaded.sh" "$3"
}
fresh_fail2ban_preflight() { :; }
cloud-init() { [[ $1 == status ]] || return 1; printf 'status: disabled\n'; }
check_ssh() { [[ $1 == 56789 ]]; }
check_sources() { :; }
check_resources() { :; }
installed() { [[ $1 == linux-image-6.12.113+deb13-cloud-amd64 ]]; }
dpkg-query() { printf 'Debian Kernel Team <debian-kernel@lists.debian.org>\n'; }
memtotal() { printf '2097152\n'; }
swap_plan() { printf 'disk\n'; }
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
        self.assertEqual(self.read_state(self.result)["swap_bytes"], "2147483648")
        self.assertEqual(self.calls.read_text(), "LAUNCH\n")

    def test_cloud_init_pending_or_error_stops_before_persisting_task(self) -> None:
        for status, exit_code in (("not started", 0), ("running", 2), ("error", 1)):
            with self.subTest(status=status):
                proc = self.initialize(
                    f"cloud-init() {{ printf 'status: {status}\\n'; return {exit_code}; }}",
                    check=False,
                )
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("cloud-init", proc.stderr)
                self.assertFalse(self.task.exists())
                self.assertFalse(self.result.exists())

    def test_effective_cloud_init_hosts_policy_takes_precedence_over_system_config(self) -> None:
        fixture = r'''
cloud-init() {
    case $* in
        'status --long') printf 'status: done\nextended_status: degraded done\n'; return 2 ;;
        'query combined_cloud_config.manage_etc_hosts') printf '%s\n' "$EFFECTIVE" ;;
        'query merged_system_cfg.manage_etc_hosts') printf '%s\n' "$SYSTEM" ;;
        *) return 1 ;;
    esac
}
cloud_init_preflight
'''
        proc = self.run_shell("EFFECTIVE=' yes '; SYSTEM=false\n" + fixture, check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("/etc/hosts", proc.stderr)
        self.run_shell("EFFECTIVE=false; SYSTEM=true\n" + fixture)

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

    def test_interrupted_state_write_preserves_committed_state_and_resumes(self) -> None:
        self.initialize("cp() { return 73; }", check=False)
        stage = self.task / ".state-pending"
        stage.write_text("incomplete scratch data")
        stage.chmod(0o600)
        self.assertEqual(self.read_state(self.state)["task_id"], TASK)
        self.resume()
        self.assertFalse(stage.exists())
        self.assertEqual(self.read_state(self.state)["task_id"], TASK)

    def test_partial_config_is_reused_and_leaves_no_staging_file(self) -> None:
        self.initialize()
        self.run_shell(r'''
parse_state "$STATE_FILE"
config=$FIXTURE_ROOT/new.conf
stage=$FIXTURE_ROOT/.next-vps-setup-config.${S[task_id]}.new.conf
printf 'sett' > "$stage"
chmod 0600 "$stage"
publish_config "$config" 'setting=1'
[[ $(cat "$config") == 'setting=1' && ! -e $stage ]]
''')

    def test_final_index_loss_replans_without_recreating_swap(self) -> None:
        self.initialize()
        self.run_shell(r'''
parse_state "$STATE_FILE"
S[phase]=final; S[target_kernel]=6.12.113+deb13-cloud-amd64
S[boot_before]=55555555-5555-4555-8555-555555555555
S[reboot_count]=3; S[reboot_wait]=none; S[balloon]=module
S[mem_kib]=524288; S[swap_bytes]=1073741824; S[swap_policy]=disk; S[swap_uuid]=33333333-3333-4333-8333-333333333333
S[swap_status]=active; S[swap_identity]=44444444-4444-4444-8444-444444444444:12345
official_apt_ready() { return 0; }
prepare_resume_plan
[[ ${S[phase]} == final && ${S[reboot_count]} == 3 ]]
official_apt_ready() { return 1; }
prepare_resume_plan
[[ ${S[phase]} == update && ${S[target_kernel]} == - && ${S[balloon]} == pending ]]
[[ ${S[reboot_count]} == 0 && ${S[boot_before]} == - ]]
[[ ${S[swap_status]} == active && ${S[swap_identity]} == 44444444-4444-4444-8444-444444444444:12345 ]]
''')

    def test_swap_publishes_the_same_inode_after_interruption_before_rename(self) -> None:
        self.initialize()
        fixture = r'''
parse_state "$STATE_FILE"
SWAP_DIR=$FIXTURE_ROOT/final-swap
swap_mount_field() {
    [[ $1 == UUID ]] || return 97
    printf '44444444-4444-4444-8444-444444444444\n'
}
'''
        before = self.run_shell(fixture + r'''
S[mem_kib]=524288; S[swap_bytes]=1073741824; S[swap_policy]=disk; S[swap_status]=building
S[swap_uuid]=33333333-3333-4333-8333-333333333333
save_state
mkdir -m 0700 -- "$BASE/swap-staged"
printf 'format\t1\n' > "$BASE/swap-staged/owner.tsv"
mv() {
    if [[ ${!#} == "$SWAP_DIR" ]]; then return 73; fi
    command mv "$@"
}
publish_swap_directory
''', check=False)
        self.assertNotEqual(before.returncode, 0)
        staged = self.task / "swap-staged" / "swapfile"
        inode = staged.stat().st_ino
        self.assertEqual(self.read_state(self.state)["swap_identity"], f"44444444-4444-4444-8444-444444444444:{inode}")
        self.run_shell(fixture + r'''
mv() {
    if [[ ${!#} == "$SWAP_DIR" ]]; then
        [[ $* == "-T --no-copy --update=none-fail -- $BASE/swap-staged $SWAP_DIR" ]] || return 92
        [[ ! -e $SWAP_DIR && ! -L $SWAP_DIR ]] || return 93
        command mv -T -- "$BASE/swap-staged" "$SWAP_DIR"
    else command mv "$@"; fi
}
publish_swap_directory
''')
        self.assertFalse(staged.exists())
        self.assertEqual((self.root / "final-swap" / "swapfile").stat().st_ino, inode)

    def test_prepared_swap_is_reused_and_verified_before_enabling_at_boot(self) -> None:
        self.initialize()
        self.run_shell(r'''
parse_state "$STATE_FILE"
SWAP_UNIT=fixture.swap
SWAP_UNIT_FILE=$FIXTURE_ROOT/fixture.swap
SWAP_SYSCTL=$FIXTURE_ROOT/fixture.conf
SWAP_FILE=$FIXTURE_ROOT/swapfile
S[swap_status]=prepared
S[swap_uuid]=33333333-3333-4333-8333-333333333333
S[swap_identity]=44444444-4444-4444-8444-444444444444:12345
swap_filesystem_check() { :; }
swap_check_paths() { :; }
swap_check_tuning_conflicts() { :; }
swap_usable_kib() { [[ $1 == 2147483648 ]]; }
swap_verify_file() { :; }
swap_free_kib() { printf '%s\n' "$SWAP_RESERVE_KIB"; }
swap_inventory() { printf 'none\n'; }
dd() { printf 'unexpected-write\n' >> "$DANGER_LOG"; return 97; }
mkswap() { printf 'unexpected-format\n' >> "$DANGER_LOG"; return 97; }
publish_config() { printf 'config:%s\n' "$1" >> "$CALLS"; }
systemctl() { printf 'unit:%s\n' "$*" >> "$CALLS"; }
verify_swap_definition() { :; }
verify_live_swap() { printf 'live-verified\n' >> "$CALLS"; }
sysctl() { printf 'sysctl:%s\n' "$*" >> "$CALLS"; }
verify_swap() { :; }
phase_swap
''')
        calls = self.calls.read_text().splitlines()
        self.assertLess(calls.index("unit:start fixture.swap"), calls.index("live-verified"))
        self.assertLess(calls.index("live-verified"), calls.index("unit:enable fixture.swap"))
        self.assertLess(calls.index("unit:enable fixture.swap"), calls.index("sysctl:-w vm.swappiness=10"))
        self.assertEqual(self.read_state(self.state)["swap_status"], "active")
        self.assertEqual(self.read_state(self.state)["phase"], "update")

    def test_only_a_completed_legacy_initializer_receipt_is_readable(self) -> None:
        self.initialize()
        self.run_shell(r'''
parse_state "$STATE_FILE"
S[format]=3
unset 'S[swap_bytes]'
S[swap_policy]=skip; S[swap_status]=skipped
S[phase]=done; S[result_status]=complete; S[ntp_status]=unsynchronized
S[target_kernel]=6.12.113+deb13-cloud-amd64; S[reboot_count]=1
S[verified_boot]=33333333-3333-4333-8333-333333333333
S[verified_at]=1790000000
S[config_hashes]=$(printf '%064d' 0)
S[packages]=curl=8.14.1-2,
serialize_state > "$RESULT"
parse_state "$RESULT"
S[phase]=final; S[result_status]=running
serialize_state > "$RESULT"
if parse_state "$RESULT"; then exit 95; fi
''')

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
source "$INIT_LIBRARY"
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
        self.assertLess(source.index("safe_state_parent /var/lib"), source.index('nv_task_lock "$mode"'))


if __name__ == "__main__":
    unittest.main(verbosity=2)
