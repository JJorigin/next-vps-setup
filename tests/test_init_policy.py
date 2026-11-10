"""Isolated initializer policy checks; the delivery entry point is never run.

Only selected pure functions are copied from the reviewed source into an
ordinary Bash subprocess. No system package, service, Swap, or boot change is
performed. The source-order check guards rejection before task preparation.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "next-vps-setup.sh"


def function_source(name: str) -> str:
    source = SCRIPT.read_text(encoding="utf-8")
    match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}\n", source)
    if match is None:
        raise AssertionError(f"Cannot find initializer function: {name}")
    return match.group(0)


class InitializerSourceTests(unittest.TestCase):
    def test_kernel_flavour_check_precedes_any_task_preparation(self) -> None:
        source = function_source("initialize_task")
        guard = source.index('meta=$(kernel_meta_for_abi "$(uname -r)")')
        for marker in ('safe_entry_path', 'fresh_fail2ban_preflight', 'swap_plan', 'mkdir -m 0700', 'copy_worker'):
            with self.subTest(marker=marker):
                self.assertLess(guard, source.index(marker))


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Linux/WSL Bash")
class InitializerKernelPolicyTests(unittest.TestCase):
    def run_policy(self, abi: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [shutil.which("bash"), "--noprofile", "--norc", "-c",
             "set -Eeuo pipefail\n" + function_source("kernel_meta_for_abi") + '\nkernel_meta_for_abi "$1"',
             "initializer-policy-test", abi],
            env={"PATH": "/nonexistent", "LC_ALL": "C"},
            text=True, capture_output=True, timeout=10,
        )

    def test_standard_stable_kernel_names(self) -> None:
        for abi in ("6.12.0-5-amd64", "6.12.12-amd64", "6.12.113+deb13-amd64", "6.12.115+deb13.1-amd64"):
            with self.subTest(abi=abi):
                proc = self.run_policy(abi)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(proc.stdout, "linux-image-amd64\n")

    def test_cloud_stable_kernel_names(self) -> None:
        for abi in ("6.12.0-5-cloud-amd64", "6.12.12-cloud-amd64", "6.12.113+deb13-cloud-amd64", "6.12.115+deb13.1-cloud-amd64"):
            with self.subTest(abi=abi):
                proc = self.run_policy(abi)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(proc.stdout, "linux-image-cloud-amd64\n")

    def test_other_kernel_flavours_are_rejected(self) -> None:
        for abi in (
            "6.12.115+deb13.1-rt-amd64", "6.12.0-5-rt-amd64",
            "6.12.115+deb13.1-cloud-rt-amd64", "6.12.115-custom-amd64",
            "6.12.115-debug-amd64", "6.12.115-cloud-custom-amd64",
            "6.12.115+deb13.1-amd64-unsigned", "6.12.115-unsigned-amd64",
            "6.12.115+deb13.1-cloud-unsigned-amd64", "6.18.1-cloud-amd64",
            "6.12.115+deb14-amd64", "6.12.115+deb13.1-arm64",
        ):
            with self.subTest(abi=abi):
                proc = self.run_policy(abi)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(proc.stdout, "")

    def test_malformed_names_and_shell_text_are_rejected(self) -> None:
        for abi in ("", "-amd64", "6.12.0-5-amd64\n", "6.12.115+deb13..1-amd64", "$(false)", "6.12.115-amd64;false"):
            with self.subTest(abi=abi):
                proc = self.run_policy(abi)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(proc.stdout, "")

    def test_metapackage_dependency_cannot_change_kernel_flavour(self) -> None:
        body = (
            "set -Eeuo pipefail\n"
            + function_source("kernel_meta_for_abi")
            + function_source("set_target_kernel")
            + r'''
declare -A S=([kernel_meta]="$1")
check_candidate() { :; }
dpkg-query() { printf '%s\n' "$TEST_DEPENDENCY"; }
installed() { printf 'UNEXPECTED_INSTALLED_QUERY\n' >&2; exit 98; }
save_state() { printf 'UNEXPECTED_STATE_WRITE\n' >&2; exit 98; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 77; }
set_target_kernel
'''
        )
        for meta, dependency in (
            ("linux-image-amd64", "linux-image-6.12.115+deb13.1-cloud-amd64 (= 6.12.115-2)"),
            ("linux-image-cloud-amd64", "linux-image-6.12.115+deb13.1-amd64 (= 6.12.115-2)"),
            ("linux-image-amd64", "linux-image-6.12.115+deb13.1-rt-amd64 (= 6.12.115-2)"),
            ("linux-image-amd64", "linux-image-6.12.115-custom-amd64 (= 6.12.115-2)"),
        ):
            with self.subTest(meta=meta, dependency=dependency):
                proc = subprocess.run(
                    [shutil.which("bash"), "--noprofile", "--norc", "-c", body, "init-dependency-test", meta],
                    env={"PATH": "/nonexistent", "LC_ALL": "C", "TEST_DEPENDENCY": dependency},
                    text=True, capture_output=True, timeout=10,
                )
                self.assertEqual(proc.returncode, 77, proc.stdout + proc.stderr)
                self.assertIn("change the original kernel flavour", proc.stderr)
                self.assertNotIn("UNEXPECTED_", proc.stderr)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Linux/WSL Bash")
class InitializerSwapPolicyTests(unittest.TestCase):
    def run_policy(self, body: str, *args: str) -> subprocess.CompletedProcess[str]:
        source = SCRIPT.read_text(encoding="utf-8")
        constants = "\n".join(re.findall(
            r"(?m)^(?:KIB_PER_GIB|BYTES_PER_GIB|SWAP_(?:RESERVE_KIB|PREPARE_KIB|MAX_PAGES))=[0-9A-Z_$]+$", source
        ))
        helpers = "".join(map(function_source, ("swap_target_bytes", "swap_usable_kib", "swap_plan")))
        bootstrap = (
            "set -Eeuo pipefail\n" + constants
            + "\ndie() { printf '%s\\n' \"$*\" >&2; exit 77; }\n" + helpers
        )
        return subprocess.run(
            [shutil.which("bash"), "--noprofile", "--norc", "-c", bootstrap + body, "swap-policy", *args],
            env={"PATH": "/nonexistent", "LC_ALL": "C"},
            text=True, capture_output=True, timeout=10,
        )

    def test_swap_target_uses_integer_gib_boundaries(self) -> None:
        gib_kib, gib_bytes = 1048576, 1073741824
        samples = [(475784, 1), (524288, 1), (890 * 1024, 1), (1572864, 2), (2621440, 3)]
        for whole in (1, 2, 4):
            samples.extend(((whole * gib_kib - 4, whole), (whole * gib_kib, whole), (whole * gib_kib + 4, whole + 1)))
        for kib, expected in samples:
            with self.subTest(kib=kib):
                proc = self.run_policy('\nswap_target_bytes "$1"', str(kib))
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(proc.stdout, f"{expected * gib_bytes}\n")
        for invalid in ("", "0", "00", "010", "-1", "1048576 kB", "1234567890123456"):
            with self.subTest(invalid=invalid):
                proc = self.run_policy('\nswap_target_bytes "$1"', invalid)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(proc.stdout, "")

    def test_usable_swap_accounts_for_the_header_and_rejects_oversize(self) -> None:
        body = '\ngetconf() { printf "4096\\n"; }\nswap_usable_kib "$1"'
        self.assertEqual(self.run_policy(body, "2147483648").stdout, "2097148\n")
        proc = self.run_policy(body, str(16 * 1024 ** 4))
        self.assertEqual(proc.returncode, 77)
        self.assertEqual(proc.stdout, "")

    def test_plan_distinguishes_existing_swap_resource_limits_and_query_errors(self) -> None:
        body = r'''
MEMORY=$1 INVENTORY=$2 FILESYSTEM=$3 FREE_KIB=$4 WRITABLE=${5:-yes}
swap_check_paths() { :; }
swap_require_writable_varlib() { [[ $WRITABLE == yes ]]; }
swap_inventory() { [[ $INVENTORY != error ]] || return 79; printf '%s\n' "$INVENTORY"; }
swap_check_tuning_conflicts() { :; }
getconf() { printf '4096\n'; }
swap_mount_field() { printf '%s\n' "$FILESYSTEM"; }
swap_ext4_device_check() { :; }
swap_free_kib() { printf '%s\n' "$FREE_KIB"; }
swap_plan "$MEMORY" "$(swap_target_bytes "$MEMORY")"
'''
        # 2 GiB target + 1 GiB reserve + 16 MiB preparation allowance.
        need = 3 * 1048576 + 16384
        cases = (
            (("1572864", "none", "ext4", str(need)), 0, "disk\n"),
            (("1572864", "none", "ext4", str(need - 1)), 0, "skip-space\n"),
            (("1572864", "none", "xfs", str(need)), 0, "skip-filesystem\n"),
            (("524288", "none", "ext4", "2097152"), 77, ""),
            (("524288", "none", "xfs", str(need)), 77, ""),
            (("524288", "active", "ext4", str(need)), 0, "preserve\n"),
            (("524288", "configured", "ext4", str(need)), 77, ""),
            (("1572864", "configured", "ext4", str(need)), 0, "preserve\n"),
            (("1572864", "error", "ext4", str(need)), 1, ""),
            (("1572864", "none", "ext4", str(need), "no"), 1, ""),
        )
        for args, status, output in cases:
            with self.subTest(args=args):
                proc = self.run_policy(body, *args)
                self.assertEqual(proc.returncode, status, proc.stderr)
                self.assertEqual(proc.stdout, output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
