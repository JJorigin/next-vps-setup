"""Swap snapshot regressions; real swapon reads a temporary LIBMOUNT_SWAPS file.

No test enables or disables Swap. The production entry point is sourced only;
the swapon wrapper accepts exactly the read-only arguments used by swap_hash.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "next-vps-kernel-update.sh"
EXPECTED_ARGS = ["--show=NAME,SIZE,PRIO", "--noheadings", "--raw", "--bytes"]


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Linux/WSL Bash")
class SwapSnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.real_swapon = shutil.which("swapon")
        if not self.real_swapon:
            self.skipTest("read-only util-linux swapon is required")
        self.tmp = tempfile.TemporaryDirectory(prefix="next-swap-snapshot-")
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.fixture = self.root / "swaps"
        self.baseline_fixture = self.root / "baseline-swaps"
        self.argv_file = self.root / "swapon-argv"
        self.wrapper = self.bin / "swapon"
        self.wrapper.write_text(
            "#!/bin/bash\n"
            'printf "%s\\0" "$@" > "$SWAP_ARGV_FILE"\n'
            '[[ $# == 4 && $1 == --show=NAME,SIZE,PRIO && $2 == --noheadings && '
            '$3 == --raw && $4 == --bytes ]] || exit 96\n'
            f"exec {shlex.quote(self.real_swapon)} \"$@\"\n",
            encoding="utf-8", newline="\n",
        )
        self.wrapper.chmod(0o700)
        self.write_swaps()

    def tearDown(self) -> None:
        if hasattr(self, "tmp"):
            self.tmp.cleanup()

    def write_swaps(
        self, *, name: str = "/fixture/swapfile", size_kib: int = 1048572,
        used_kib: int = 13312, priority: int = 10, empty: bool = False,
    ) -> None:
        self.write_rows([] if empty else [(name, size_kib, used_kib, priority)])

    def write_rows(self, rows: list[tuple[str, int, int, int]]) -> None:
        content = "Filename\tType\tSize\tUsed\tPriority\n"
        for name, size_kib, used_kib, priority in rows:
            content += f"{name} file {size_kib} {used_kib} {priority}\n"
        self.fixture.write_text(content, encoding="utf-8", newline="\n")

    def save_baseline(self) -> None:
        self.baseline_fixture.write_bytes(self.fixture.read_bytes())

    def environment(self) -> dict[str, str]:
        env = os.environ.copy()
        env.pop("BASH_ENV", None)
        env.update({
            "PATH": f"{self.bin}:/usr/bin:/bin", "LC_ALL": "C",
            "SCRIPT": str(SCRIPT), "LIBMOUNT_SWAPS": str(self.fixture),
            "SWAP_ARGV_FILE": str(self.argv_file),
        })
        return env

    def run_hash(self, *, check: bool = True) -> subprocess.CompletedProcess[str]:
        proc = subprocess.run(
            ["bash", "-c", 'set -Eeuo pipefail\nsource "$SCRIPT"\nswap_hash\nprintf "AFTER_HASH\\n"\n'],
            env=self.environment(), text=True, capture_output=True, timeout=15,
        )
        if check:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertEqual(proc.stdout.splitlines()[-1:], ["AFTER_HASH"])
        return proc

    def digest(self) -> str:
        return self.run_hash().stdout.splitlines()[0]

    def test_arguments_select_exactly_three_columns(self) -> None:
        digest = self.digest()
        expected = hashlib.sha256(b"/fixture/swapfile 1073737728 10\n").hexdigest()
        self.assertEqual(digest, expected)
        self.assertEqual(
            self.argv_file.read_bytes().split(b"\0")[:-1],
            [arg.encode() for arg in EXPECTED_ARGS],
        )

    def test_used_changes_do_not_change_snapshot(self) -> None:
        before = self.digest()
        self.write_swaps(used_kib=256)
        self.assertEqual(self.digest(), before)

    def test_path_change_changes_snapshot(self) -> None:
        before = self.digest()
        self.write_swaps(name="/fixture/another-swapfile")
        self.assertNotEqual(self.digest(), before)

    def test_capacity_change_changes_snapshot(self) -> None:
        before = self.digest()
        self.write_swaps(size_kib=524284)
        self.assertNotEqual(self.digest(), before)

    def test_priority_change_changes_snapshot(self) -> None:
        before = self.digest()
        self.write_swaps(priority=5)
        self.assertNotEqual(self.digest(), before)

    def test_empty_swap_list_has_stable_empty_digest(self) -> None:
        self.write_swaps(empty=True)
        self.assertEqual(self.digest(), hashlib.sha256(b"").hexdigest())

    def test_multiple_swap_order_and_usage_do_not_change_snapshot(self) -> None:
        self.write_rows([
            ("/fixture/z-swap", 1048572, 13312, 10),
            ("/fixture/a-swap", 524284, 256, 5),
        ])
        before = self.digest()
        expected = b"/fixture/a-swap 536866816 5\n/fixture/z-swap 1073737728 10\n"
        self.assertEqual(before, hashlib.sha256(expected).hexdigest())
        self.write_rows([
            ("/fixture/a-swap", 524284, 0, 5),
            ("/fixture/z-swap", 1048572, 64, 10),
        ])
        self.assertEqual(self.digest(), before)

    def test_added_swap_changes_snapshot(self) -> None:
        before = self.digest()
        self.write_rows([
            ("/fixture/swapfile", 1048572, 13312, 10),
            ("/fixture/extra-swap", 524284, 0, 5),
        ])
        self.assertNotEqual(self.digest(), before)

    def test_removed_swap_changes_snapshot(self) -> None:
        before = self.digest()
        self.write_swaps(empty=True)
        self.assertNotEqual(self.digest(), before)

    def test_swapped_priorities_change_multiple_swap_snapshot(self) -> None:
        self.write_rows([
            ("/fixture/a-swap", 1048572, 0, 10),
            ("/fixture/b-swap", 1048572, 0, 5),
        ])
        before = self.digest()
        self.write_rows([
            ("/fixture/a-swap", 1048572, 0, 5),
            ("/fixture/b-swap", 1048572, 0, 10),
        ])
        self.assertNotEqual(self.digest(), before)

    def test_failed_swapon_stops_caller(self) -> None:
        self.wrapper.write_text("#!/bin/bash\nexit 23\n", encoding="utf-8", newline="\n")
        proc = self.run_hash(check=False)
        self.assertEqual(proc.returncode, 23, proc.stdout + proc.stderr)
        self.assertNotIn("AFTER_HASH", proc.stdout)

    def assert_conditional_hash_rejected(self, expected: str) -> None:
        env = self.environment()
        env["EXPECTED_HASH"] = expected
        proc = subprocess.run(
            ["bash", "-c", 'set -Eeuo pipefail\nsource "$SCRIPT"\n'
             'if [[ $(swap_hash) == "$EXPECTED_HASH" ]]; then\n'
             '    printf "UNEXPECTED_MATCH\\n"\n    exit 98\nfi\n'
             'printf "REJECTED\\n"\n'],
            env=env, text=True, capture_output=True, timeout=15,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(proc.stdout, "REJECTED\n")

    def test_failed_empty_swapon_is_not_an_empty_snapshot(self) -> None:
        self.wrapper.write_text("#!/bin/bash\nexit 23\n", encoding="utf-8", newline="\n")
        proc = self.run_hash(check=False)
        self.assertEqual(proc.returncode, 23, proc.stdout + proc.stderr)
        self.assertEqual(proc.stdout, "")
        self.assert_conditional_hash_rejected(hashlib.sha256(b"").hexdigest())

    def test_failed_partial_swapon_is_not_a_valid_snapshot(self) -> None:
        row = "/fixture/swapfile 1073737728 10\n"
        self.wrapper.write_text(
            "#!/bin/bash\nprintf '%s' " + shlex.quote(row) + "\nexit 23\n",
            encoding="utf-8", newline="\n",
        )
        proc = self.run_hash(check=False)
        self.assertEqual(proc.returncode, 23, proc.stdout + proc.stderr)
        self.assertEqual(proc.stdout, "")
        self.assert_conditional_hash_rejected(hashlib.sha256(row.encode()).hexdigest())

    def test_old_output_abbreviation_includes_used_column(self) -> None:
        args = [self.real_swapon, "--show", "--noheadings", "--raw", "--bytes", "--output", "NAME,SIZE,PRIO"]
        before = subprocess.run(args, env=self.environment(), text=True, capture_output=True, timeout=15)
        self.assertEqual(before.returncode, 0, before.stderr)
        self.assertEqual(before.stdout.split()[:5], ["/fixture/swapfile", "file", "1073737728", "13631488", "10"])
        self.write_swaps(used_kib=256)
        after = subprocess.run(args, env=self.environment(), text=True, capture_output=True, timeout=15)
        self.assertEqual(after.returncode, 0, after.stderr)
        self.assertEqual(after.stdout.split()[:5], ["/fixture/swapfile", "file", "1073737728", "262144", "10"])
        self.assertNotEqual(hashlib.sha256(before.stdout.encode()).digest(), hashlib.sha256(after.stdout.encode()).digest())

    def run_preserved_check(
        self, *, current_swappiness: str = "10", baseline_swappiness: str = "10",
        current_swappiness_status: str = "0",
    ) -> subprocess.CompletedProcess[str]:
        """Run the actual verifier; substitute unrelated SSH/service dependencies.

        The absolute sshd command is a Bash function, so no real daemon or host
        configuration is inspected. Swap data still comes from real swapon.
        """
        env = self.environment()
        env.update({
            "BASELINE_SWAPS": str(self.baseline_fixture),
            "CURRENT_SWAPPINESS": current_swappiness,
            "CURRENT_SWAPPINESS_STATUS": current_swappiness_status,
            "BASELINE_SWAPPINESS": baseline_swappiness,
            "TEST_SYS_DIR": str(self.root / "sys"),
        })
        body = r'''
set -Eeuo pipefail
source "$SCRIPT"
die() { printf 'VERIFY_ERROR:%s\n' "$*" >&2; exit 42; }
config_hash() { printf 'persistent-fixture\n'; }
ssh_hash() { printf 'ssh-fixture\n'; }
function /usr/sbin/sshd {
    [[ $# == 1 && $1 == -t ]] || die 'Unexpected sshd call.'
}
sysctl() {
    [[ $# == 2 && $1 == -n && $2 == vm.swappiness ]] || die 'Unexpected sysctl call.'
    printf '%s\n' "$CURRENT_SWAPPINESS"
    return "$CURRENT_SWAPPINESS_STATUS"
}
systemctl() {
    [[ $# == 3 && $1 == is-active && $2 == --quiet ]] || die 'Unexpected systemctl call.'
    case $3 in ssh.service|fail2ban.service|x-ui.service) return 0 ;; *) die 'Unexpected service.' ;; esac
}
fail2ban-client() { [[ $# == 2 && $1 == status && $2 == sshd ]]; }
ssh_listening() { return 0; }
balloon_mode() { printf 'module\n'; }
modprobe() {
    [[ $# == 3 && $1 == -n && $2 == -v && $3 == virtio_balloon ]] || die 'Unexpected modprobe call.'
    printf 'install /bin/false\n'
}
sleep() { die 'Unexpected retry wait.'; }
SYS_DIR=$TEST_SYS_DIR
S[config_sha]=$(config_hash)
S[ssh_sha]=$(ssh_hash)
S[swap_sha]=$(LIBMOUNT_SWAPS="$BASELINE_SWAPS" swap_hash)
S[swappiness]=$BASELINE_SWAPPINESS
S[services]=ssh.service,fail2ban.service,x-ui.service
S[target_abi]=fixture-amd64
verify_preserved
printf 'PRESERVED_OK\n'
'''
        return subprocess.run(
            ["bash", "-c", body], env=env, text=True, capture_output=True, timeout=15,
        )

    def assert_preserved(self, **kwargs: str) -> None:
        proc = self.run_preserved_check(**kwargs)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(proc.stdout, "PRESERVED_OK\n")

    def assert_swap_rejected(
        self, *, expected_error: str = "Swap 的路径、容量或优先级与更新前不一致",
        **kwargs: str,
    ) -> None:
        proc = self.run_preserved_check(**kwargs)
        self.assertEqual(proc.returncode, 42, proc.stdout + proc.stderr)
        self.assertIn(expected_error, proc.stderr)
        self.assertNotIn("PRESERVED_OK", proc.stdout)

    def test_verifier_accepts_usage_change(self) -> None:
        self.save_baseline()
        self.write_swaps(used_kib=256)
        self.assert_preserved()

    def test_verifier_accepts_multiple_swap_reordering_and_usage_change(self) -> None:
        self.write_rows([
            ("/fixture/z-swap", 1048572, 13312, 10),
            ("/fixture/a-swap", 524284, 256, 5),
        ])
        self.save_baseline()
        self.write_rows([
            ("/fixture/a-swap", 524284, 0, 5),
            ("/fixture/z-swap", 1048572, 64, 10),
        ])
        self.assert_preserved()

    def test_verifier_accepts_unchanged_no_swap_and_swappiness(self) -> None:
        self.write_swaps(empty=True)
        self.save_baseline()
        self.assert_preserved(current_swappiness="60", baseline_swappiness="60")

    def test_verifier_rejects_path_change(self) -> None:
        self.save_baseline()
        self.write_swaps(name="/fixture/replacement")
        self.assert_swap_rejected()

    def test_verifier_rejects_capacity_change(self) -> None:
        self.save_baseline()
        self.write_swaps(size_kib=524284)
        self.assert_swap_rejected()

    def test_verifier_rejects_priority_change(self) -> None:
        self.save_baseline()
        self.write_swaps(priority=5)
        self.assert_swap_rejected()

    def test_verifier_rejects_swappiness_change(self) -> None:
        self.save_baseline()
        self.assert_swap_rejected(
            current_swappiness="60", expected_error="swappiness 与更新前不一致：原值 10，当前值 60",
        )

    def test_verifier_rejects_failed_swappiness_read(self) -> None:
        self.save_baseline()
        self.assert_swap_rejected(
            current_swappiness="", current_swappiness_status="23",
            expected_error="无法读取当前 swappiness",
        )

    def test_verifier_rejects_partial_failed_swappiness_read(self) -> None:
        self.save_baseline()
        self.assert_swap_rejected(
            current_swappiness="10", current_swappiness_status="23",
            expected_error="无法读取当前 swappiness",
        )

    def test_verifier_rejects_missing_swap(self) -> None:
        self.save_baseline()
        self.write_swaps(empty=True)
        self.assert_swap_rejected()

    def test_verifier_rejects_added_swap(self) -> None:
        self.save_baseline()
        self.write_rows([
            ("/fixture/swapfile", 1048572, 13312, 10),
            ("/fixture/extra-swap", 524284, 0, 5),
        ])
        self.assert_swap_rejected()

    def test_verifier_rejects_failed_swap_read_for_empty_snapshot(self) -> None:
        self.write_swaps(empty=True)
        self.save_baseline()
        wrapper = self.wrapper.read_text(encoding="utf-8")
        self.wrapper.write_text(
            wrapper.replace("exec ", '[[ $LIBMOUNT_SWAPS == "$BASELINE_SWAPS" ]] || exit 23\nexec ', 1),
            encoding="utf-8", newline="\n",
        )
        self.assert_swap_rejected(
            current_swappiness="60", baseline_swappiness="60", expected_error="无法读取当前 Swap 状态",
        )

    def test_verifier_rejects_partial_failed_swap_read(self) -> None:
        self.save_baseline()
        wrapper = self.wrapper.read_text(encoding="utf-8")
        failure = (
            'if [[ $LIBMOUNT_SWAPS != "$BASELINE_SWAPS" ]]; then\n'
            "    printf '/fixture/swapfile 1073737728 10\\n'\n    exit 23\nfi\n"
        )
        self.wrapper.write_text(
            wrapper.replace("exec ", failure + "exec ", 1), encoding="utf-8", newline="\n",
        )
        self.assert_swap_rejected(expected_error="无法读取当前 Swap 状态")


if __name__ == "__main__":
    unittest.main()
