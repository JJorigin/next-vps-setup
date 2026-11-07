"""One-time notice tests, using only ordinary-user temporary directories.

The source fragment is embedded unchanged apart from explicit helper overrides
for root identity and the temporary directory boundary. No /etc or /var writes,
real login changes, services, APT, reboot, or network calls are performed.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[1] / "lib/ssh-notice.sh"
APP = "next-vps-setup"
TASK = "11111111-1111-4111-8111-111111111111"
NEXT_TASK = "22222222-2222-4222-8222-222222222222"


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Linux/WSL")
class SshNoticeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="next-ssh-notice-")
        self.root = Path(self.temp.name)
        self.profile = self.root / "profile.d"
        self.data = self.root / "data"
        self.lock_dir = self.root / "root-home"
        self.profile.mkdir(mode=0o700)
        self.data.mkdir(mode=0o700)
        self.lock_dir.mkdir(mode=0o700)
        self.hook = self.profile / f"{APP}-notice.sh"
        self.payload = self.data / f"{APP}-notice"
        self.receipt = self.data / f"{APP}-result.tsv"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def env(self, **updates: str) -> dict[str, str]:
        env = os.environ.copy()
        env.update({
            "NOTICE_MODULE": str(MODULE), "NOTICE_ROOT": str(self.root),
            "NV_NOTICE_PROFILE_DIR": str(self.profile), "NV_NOTICE_DATA_ROOT": str(self.data),
            "NV_NOTICE_LOCK_DIR": str(self.lock_dir),
            "HOOK": str(self.hook), "TEST_ROOT": "yes", "LC_ALL": "C.UTF-8",
            "SSH_CONNECTION": "198.51.100.1 54321 203.0.113.1 56789",
        })
        env.update(updates)
        return env

    def shell(self, body: str, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        bootstrap = r'''
set -Eeuo pipefail
source "$NOTICE_MODULE"
nv_notice_is_root() { [[ ${TEST_ROOT:-yes} == yes ]]; }
nv_notice_owner() { /usr/bin/id -u; }
nv_notice_safe_dir() {
    local mode
    [[ ( $1 == "$NOTICE_ROOT" || $1 == "$NOTICE_ROOT"/* ) && -d $1 && ! -L $1 ]] || return 1
    [[ $(stat -c %u -- "$1") == "$(id -u)" ]] || return 1
    mode=$(stat -c %a -- "$1")
    (( (8#$mode & 022) == 0 ))
}
'''
        proc = subprocess.run(["bash", "--noprofile", "--norc", "-c", bootstrap + body, "test", *args], env=self.env(), text=True, capture_output=True, timeout=20)
        if check:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def write_receipt(self, *, task: str = TASK, phase: str = "done", status: str = "complete", failed: str = "no") -> None:
        self.receipt.write_text(f"task_id\t{task}\nphase\t{phase}\nresult_status\t{status}\nfailed\t{failed}\n", encoding="utf-8")
        self.receipt.chmod(0o600)

    def install(self, *, app: str = APP, kind: str = "success", task: str = TASK, stage: str = "done", ntp: str = "synchronized", entry: str = "/root/next-vps-setup.sh", check: bool = True) -> subprocess.CompletedProcess[str]:
        return self.shell('\nnv_notice_install "$1" "$2" "$3" "$4" "$5" "$6"\n', app, kind, task, stage, ntp, entry, check=check)

    def login(self, *, interactive: bool = True, body: str = 'source "$HOOK"', **updates: str) -> subprocess.CompletedProcess[str]:
        flags = "-ic" if interactive else "-c"
        return subprocess.run(["bash", "--noprofile", "--norc", flags, body], env=self.env(**updates), text=True, capture_output=True, timeout=20, stdin=subprocess.DEVNULL)

    def assert_notice_gone(self) -> None:
        self.assertFalse(self.hook.exists())
        self.assertFalse(self.payload.exists())
        self.assertEqual(list(self.profile.iterdir()), [])
        self.assertEqual(list(self.data.iterdir()), [self.receipt])
        self.assertEqual(list(self.lock_dir.iterdir()), [])

    def test_source_only_defines_functions_and_creates_nothing(self) -> None:
        proc = self.shell('\nprintf "SOURCE_OK\\n"\n')
        self.assertEqual(proc.stdout, "SOURCE_OK\n")
        self.assertEqual(list(self.profile.iterdir()), [])
        self.assertEqual(list(self.data.iterdir()), [])

    def test_first_root_interactive_ssh_login_displays_success_and_cleans(self) -> None:
        self.write_receipt()
        self.install()
        before = self.receipt.read_bytes()
        proc = self.login()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("VPS 初始化已完成", proc.stdout)
        self.assertIn("状态：成功", proc.stdout)
        self.assertIn("cat /var/lib/next-vps-setup-result.tsv", proc.stdout)
        self.assert_notice_gone()
        self.assertEqual(self.receipt.read_bytes(), before)

    def test_unsynchronized_success_has_warning_without_becoming_failure(self) -> None:
        self.write_receipt()
        self.install(ntp="unsynchronized")
        proc = self.login()
        self.assertIn("状态：成功", proc.stdout)
        self.assertIn("时间同步警告", proc.stdout)
        self.assert_notice_gone()

    def test_failure_shows_stage_journal_and_resume_command_then_cleans(self) -> None:
        self.write_receipt(phase="configure", status="running", failed="yes")
        self.install(kind="failure", stage="configure", ntp="unavailable")
        proc = self.login()
        self.assertIn("状态：失败", proc.stdout)
        self.assertIn("出错阶段：配置系统基础设置", proc.stdout)
        self.assertIn("tail -n 100 /var/lib/next-vps-setup/next-vps-setup.log", proc.stdout)
        self.assertIn("journalctl -u next-vps-setup.service -n 100 --no-pager", proc.stdout)
        self.assertIn("bash /root/next-vps-setup.sh --resume", proc.stdout)
        self.assert_notice_gone()

    def test_nonroot_nonssh_and_noninteractive_do_not_read_or_consume(self) -> None:
        self.write_receipt()
        self.install()
        payload = (self.payload / "notice.txt").read_bytes()
        for options in ({"TEST_ROOT": "no"}, {"SSH_CONNECTION": ""}, {"interactive": False}):
            with self.subTest(options=options):
                proc = self.login(**options)
                self.assertNotIn("已完成", proc.stdout)
                self.assertTrue(self.hook.exists())
                self.assertEqual((self.payload / "notice.txt").read_bytes(), payload)
                self.assertFalse((self.payload / "consumed.txt").exists())
        self.login()
        self.assert_notice_gone()

    def test_staged_success_does_not_consume_running_or_cleanup_pending_receipt(self) -> None:
        self.write_receipt(phase="install", status="running")
        self.install()
        for phase, status in (("install", "running"), ("cleanup", "cleanup_pending")):
            self.write_receipt(phase=phase, status=status)
            proc = self.login()
            self.assertNotIn("已完成", proc.stdout)
            self.assertTrue((self.payload / "notice.txt").exists())
            self.assertTrue(self.hook.exists())
        self.write_receipt()
        self.assertIn("已完成", self.login().stdout)
        self.assert_notice_gone()

    def test_failure_notice_not_consumed_before_failed_receipt_is_durable(self) -> None:
        self.write_receipt(phase="install", status="running")
        self.install(kind="failure", stage="install")
        self.assertNotIn("状态：失败", self.login().stdout)
        self.assertTrue((self.payload / "notice.txt").exists())
        self.write_receipt(phase="install", status="running", failed="yes")
        self.assertIn("状态：失败", self.login().stdout)
        self.assert_notice_gone()

    def test_old_or_malformed_result_never_consumes_current_notice(self) -> None:
        self.install()
        self.write_receipt(task=NEXT_TASK)
        self.assertNotIn("已完成", self.login().stdout)
        self.receipt.write_bytes(b"task_id\t" + TASK.encode() + b"\nphase\tdone\nresult_status\tcomplete\nfailed\tno\nfailed\tyes\n")
        self.assertNotIn("已完成", self.login().stdout)
        self.assertTrue((self.payload / "notice.txt").exists())

    def test_two_concurrent_logins_consume_exactly_once_and_leave_no_lock(self) -> None:
        self.write_receipt()
        self.install()
        # Both shell processes already have the original hook bytes, just as
        # two profile readers can open a hook before the first unlinks it.
        copy = self.root / "already-open-hook.sh"
        copy.write_bytes(self.hook.read_bytes())
        body = f'source "{copy}"'
        commands = [["bash", "--noprofile", "--norc", "-ic", body] for _ in range(2)]
        processes = [subprocess.Popen(cmd, env=self.env(), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL) for cmd in commands]
        results = [p.communicate(timeout=20) for p in processes]
        self.assertTrue(all(p.returncode == 0 for p in processes), results)
        self.assertEqual(sum(out.count("VPS 初始化已完成") for out, _ in results), 1)
        self.assert_notice_gone()

    def test_public_profile_lock_does_not_block_new_notice(self) -> None:
        import fcntl

        fd = os.open(self.profile, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.write_receipt()
            self.install()
            self.assertIn("已完成", self.login().stdout)
            self.assert_notice_gone()
        finally:
            os.close(fd)

    def test_busy_private_lock_defers_login_without_consuming_notice(self) -> None:
        import fcntl

        self.write_receipt()
        self.install()
        fd = os.open(self.lock_dir, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotIn("已完成", self.login().stdout)
            self.assertTrue((self.payload / "notice.txt").exists())
        finally:
            os.close(fd)
        self.assertIn("已完成", self.login().stdout)
        self.assert_notice_gone()

    def test_public_lock_directory_is_rejected_without_staging_notice(self) -> None:
        self.lock_dir.chmod(0o755)
        proc = self.install(check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("root 通知锁", proc.stderr)
        self.assertEqual(list(self.profile.iterdir()), [])
        self.assertEqual(list(self.data.iterdir()), [])

    def test_modified_payload_is_neither_displayed_nor_deleted(self) -> None:
        self.write_receipt()
        self.install()
        pending = self.payload / "notice.txt"
        pending.write_text("tampered payload", encoding="utf-8")
        proc = self.login()
        self.assertNotIn("tampered payload", proc.stdout)
        self.assertIn("通知未完全清理", proc.stderr)
        self.assertEqual(pending.read_text(), "tampered payload")
        self.assertTrue(self.hook.exists())

    def test_unknown_residual_prevents_any_notification_deletion(self) -> None:
        self.write_receipt()
        self.install()
        unknown = self.payload / "user-owned-data"
        unknown.write_text("must survive", encoding="utf-8")
        proc = self.login()
        self.assertIn("通知未完全清理", proc.stderr)
        self.assertNotIn("已完成", proc.stdout)
        self.assertEqual(unknown.read_text(), "must survive")
        self.assertTrue((self.payload / "notice.txt").exists())

    def test_payload_symlink_does_not_read_or_remove_its_target(self) -> None:
        self.write_receipt()
        self.install()
        outside = self.root / "outside-secret"
        outside.write_text("must not read", encoding="utf-8")
        pending = self.payload / "notice.txt"
        pending.unlink()
        pending.symlink_to(outside)
        proc = self.login()
        self.assertNotIn("must not read", proc.stdout)
        self.assertTrue(pending.is_symlink())
        self.assertEqual(outside.read_text(), "must not read")

    def test_claimed_notification_retries_cleanup_without_redisplay(self) -> None:
        self.write_receipt()
        self.install()
        # Simulate a normal cleanup failure after the display claim. Keep the
        # payload on disk, report the failure, then retry on the next login.
        first = self.login(body=r'''
rm() { printf 'simulated cleanup failure\n' >&2; return 73; }
source "$HOOK"
''')
        self.assertIn("已完成", first.stdout)
        self.assertIn("通知未完全清理", first.stderr)
        self.assertFalse((self.payload / "notice.txt").exists())
        self.assertTrue((self.payload / "consumed.txt").exists())
        second = self.login()
        self.assertNotIn("已完成", second.stdout)
        self.assert_notice_gone()

    def test_resume_can_replace_a_verified_previous_failure_notice(self) -> None:
        self.write_receipt(phase="configure", status="running", failed="yes")
        self.install(kind="failure", stage="configure")
        previous = self.hook.read_bytes()
        self.install(task=NEXT_TASK, kind="success")
        self.assertNotEqual(previous, self.hook.read_bytes())
        self.write_receipt(task=NEXT_TASK)
        proc = self.login()
        self.assertIn("状态：成功", proc.stdout)
        self.assertNotIn("状态：失败", proc.stdout)
        self.assert_notice_gone()

    def test_legacy_hook_is_verified_replaced_and_cannot_consume_new_notice(self) -> None:
        self.write_receipt(phase="configure", status="running", failed="yes")
        self.install(kind="failure", stage="configure")
        self.shell(r'''
NV_NOTICE_APP=next-vps-setup
nv_notice_paths
nv_notice_load_existing
nv_notice_render_hook 1 > "$NV_NOTICE_HOOK"
''')
        previous = self.root / "legacy-open-hook.sh"
        previous.write_bytes(self.hook.read_bytes())
        self.assertTrue(previous.read_bytes().startswith(b"# next-vps-ssh-notice 1\n"))
        self.install(task=NEXT_TASK)
        self.write_receipt(task=NEXT_TASK)
        proc = self.login(body=f'source "{previous}"')
        self.assertNotIn("已完成", proc.stdout)
        self.assertTrue(self.hook.read_bytes().startswith(b"# next-vps-ssh-notice 2\n"))
        self.assertIn("已完成", self.login().stdout)
        self.assert_notice_gone()

    def test_modified_hook_is_not_overwritten_by_another_installation(self) -> None:
        self.install()
        with self.hook.open("a", encoding="utf-8") as file:
            file.write("# unexpected edit\n")
        before = self.hook.read_bytes()
        proc = self.install(task=NEXT_TASK, check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.hook.read_bytes(), before)

    def test_posix_dash_login_does_not_parse_bash_body_or_consume_notice(self) -> None:
        if not shutil.which("dash"):
            self.skipTest("dash not available")
        self.write_receipt()
        self.install()
        proc = subprocess.run(["dash", "-c", '. "$HOOK"; printf "SHELL_OK\\n"'], env=self.env(), capture_output=True, text=True, timeout=20)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "SHELL_OK\n")
        self.assertNotIn("Syntax error", proc.stderr)
        self.assertTrue((self.payload / "notice.txt").exists())
        self.assertTrue(self.hook.exists())

    def test_success_card_is_complete_without_requiring_another_check(self) -> None:
        self.write_receipt()
        self.install()
        proc = self.login()
        self.assertIn("可继续使用服务器", proc.stdout)
        self.assertIn("如需查看详细记录", proc.stdout)
        self.assertNotIn("下一条命令", proc.stdout)
        self.assertNotIn(TASK, proc.stdout)
        self.assert_notice_gone()

    def test_failure_install_after_unpublished_hook_error_cleans_temporary_files(self) -> None:
        body = r'''
mv() {
    local target=${!#}
    if [[ $target == "$HOOK" ]]; then return 73; fi
    /bin/mv "$@"
}
nv_notice_install next-vps-setup success 11111111-1111-4111-8111-111111111111 done synchronized /root/next-vps-setup.sh
'''
        proc = self.shell(body, check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(list(self.profile.iterdir()), [])
        self.assertEqual(list(self.data.iterdir()), [])

    def test_conditional_failure_trap_context_does_not_disable_install_guards(self) -> None:
        body = r'''
mktemp() { return 73; }
nv_notice_text() { printf 'UNEXPECTED_WRITE\n' >> "$NOTICE_ROOT/unexpected"; }
if nv_notice_install next-vps-setup failure 11111111-1111-4111-8111-111111111111 install unavailable /root/next-vps-setup.sh; then
    printf 'UNEXPECTED_SUCCESS\n'
else
    printf 'EXPECTED_FAILURE\n'
fi
'''
        proc = self.shell(body)
        self.assertEqual(proc.stdout, "EXPECTED_FAILURE\n")
        self.assertFalse((self.root / "unexpected").exists())
        self.assertEqual(list(self.profile.iterdir()), [])
        self.assertEqual(list(self.data.iterdir()), [])

    def test_conditional_text_write_error_cleans_temporary_objects(self) -> None:
        body = r'''
nv_notice_text() { printf 'partial'; return 74; }
if nv_notice_install next-vps-setup failure 11111111-1111-4111-8111-111111111111 install unavailable /root/next-vps-setup.sh; then
    printf 'UNEXPECTED_SUCCESS\n'
else
    printf 'EXPECTED_FAILURE\n'
fi
'''
        proc = self.shell(body)
        self.assertEqual(proc.stdout, "EXPECTED_FAILURE\n")
        self.assertEqual(list(self.profile.iterdir()), [])
        self.assertEqual(list(self.data.iterdir()), [])

    def test_stale_already_open_hook_does_not_consume_new_generation(self) -> None:
        self.write_receipt()
        self.install()
        old_copy = self.root / "already-open-old-hook.sh"
        old_copy.write_bytes(self.hook.read_bytes())
        self.install(task=NEXT_TASK)
        self.write_receipt(task=NEXT_TASK)
        first = self.login(body=f'source "{old_copy}"')
        self.assertNotIn("已完成", first.stdout)
        self.assertTrue((self.payload / "notice.txt").exists())
        self.assertIn("已完成", self.login().stdout)
        self.assert_notice_gone()

    def test_running_status_invalid_paths_and_injections_create_nothing(self) -> None:
        cases = [
            {"kind": "running"}, {"app": "../../etc"}, {"task": "bad"},
            {"stage": "done;touch injected"}, {"ntp": "$(touch injected)"},
            {"entry": "/root/foo.sh;touch-injected.sh"}, {"entry": "/root/../etc/bad.sh"},
            {"entry": "/tmp/next-vps-setup.sh"}, {"entry": "/root/$(touch injected).sh"},
        ]
        for options in cases:
            with self.subTest(options=options):
                proc = self.install(check=False, **options)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(list(self.profile.iterdir()), [])
                self.assertEqual(list(self.data.iterdir()), [])
                self.assertFalse((self.root / "injected").exists())


if __name__ == "__main__":
    unittest.main()
