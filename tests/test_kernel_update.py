"""Isolated policy tests: never call real APT, reboot, or system configuration writes.

Run on Linux/WSL: python3 -m unittest discover -s tests -v
Every shell is unprivileged, gets temporary paths, and has dangerous commands
replaced by deny-by-default stubs. Production ``main`` is never executed.
"""

from __future__ import annotations

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "next-vps-kernel-update.sh"
META = "linux-image-cloud-amd64"
ABI = "6.12.115+deb13.1-cloud-amd64"
TARGET = "linux-image-" + ABI
OLD1 = "linux-image-6.12.107+deb13-cloud-amd64"
OLD2 = "linux-image-6.12.113+deb13-cloud-amd64"
PKG_VERSION = "6.12.115-2"
BEFORE = "11111111-1111-4111-8111-111111111111"
AFTER = "22222222-2222-4222-8222-222222222222"
MAINTAINER = "Debian Kernel Team <debian-kernel@lists.debian.org>"


def row(name: str, version: str, status: str = "installed", maintainer: str = MAINTAINER) -> str:
    return "\t".join((status, name, version, maintainer))


def inventory(*extra: str) -> str:
    return "\n".join((row(META, PKG_VERSION), row(TARGET, PKG_VERSION), *extra))


def valid_state() -> dict[str, str]:
    return {
        "format": "1", "version": "1.2", "task_id": BEFORE,
        "machine_id": "a" * 32, "phase": "install", "failed": "no",
        "result_status": "running", "meta": META, "meta_version": "-",
        "target_pkg": "-", "target_abi": "-", "target_version": "-",
        "boot_before": BEFORE, "verified_boot": "-", "reboots": "0",
        "entry": "/root/next-vps-kernel-update.sh", "entry_id": "2049:123",
        "script_sha": "a" * 64, "config_sha": "b" * 64,
        "ssh_sha": "c" * 64, "swap_sha": "d" * 64, "swappiness": "10",
        "services": "ssh.service,fail2ban.service", "balloon": "module",
        "removed": "-", "verified_at": "0", "purge_sha": "-",
    }


def assignments(state: dict[str, str]) -> str:
    return "S=()\n" + "\n".join(f"S[{key}]={shlex.quote(value)}" for key, value in state.items())


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Linux/WSL Bash")
class KernelPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="next-kernel-test-")
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.danger_log = self.root / "blocked-commands.log"
        self.calls = self.root / "calls.log"
        self.danger_names = (
            "apt", "apt-get", "apt-cache", "apt-mark", "apt-config",
            "dpkg-query", "systemctl", "systemd-run", "reboot", "shutdown",
            "poweroff", "update-initramfs", "update-grub", "grub-install",
            "modprobe", "swapon", "swapoff", "sysctl", "mount", "umount",
            "hostnamectl", "timedatectl", "fail2ban-client", "install",
        )
        for name in self.danger_names:
            self.stub(name, '#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$DANGER_LOG"\nexit 97\n')
        real_dpkg = shutil.which("dpkg")
        if not real_dpkg:
            self.skipTest("Debian dpkg --compare-versions is needed for version-policy tests")
        self.stub(
            "dpkg",
            "#!/bin/bash\n"
            'if [[ ${1:-} == --compare-versions && $# == 4 ]]; then\n'
            f"  exec {shlex.quote(real_dpkg)} \"$@\"\n"
            "fi\n"
            'printf "%s\\n" "$0 $*" >> "$DANGER_LOG"\nexit 97\n',
        )

    def tearDown(self) -> None:
        try:
            if self.danger_log.exists():
                self.fail("a test attempted a forbidden command:\n" + self.danger_log.read_text())
        finally:
            self.tmp.cleanup()

    def stub(self, name: str, content: str) -> None:
        path = self.bin / name
        path.write_text(content, encoding="utf-8", newline="\n")
        path.chmod(0o700)

    def run_bash(self, body: str, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update({
            "PATH": f"{self.bin}:/usr/bin:/bin", "LC_ALL": "C",
            "DANGER_LOG": str(self.danger_log), "CALLS": str(self.calls),
            "SCRIPT": str(SCRIPT), "FIXTURE_ROOT": str(self.root),
        })
        bootstrap = r'''
set -Eeuo pipefail
source "$SCRIPT"
BASE=$FIXTURE_ROOT/task
STATE=$BASE/state.tsv
WORKER=$BASE/worker.sh
LOG=$BASE/run.log
PURGE_MANIFEST=$BASE/purge.tsv
RESULT=$FIXTURE_ROOT/result.tsv
UNIT_FILE=$FIXTURE_ROOT/unit.service
BOOT_DIR=$FIXTURE_ROOT/boot
PROC_DIR=$FIXTURE_ROOT/proc
SYS_DIR=$FIXTURE_ROOT/sys
'''
        proc = subprocess.run(
            ["bash", "-c", bootstrap + "\n" + body, "test", *args],
            env=env, cwd=self.root, text=True, capture_output=True, timeout=30,
        )
        if check:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def test_source_has_no_external_side_effects(self) -> None:
        self.assertEqual(self.run_bash('printf "SOURCE_OK\\n"').stdout, "SOURCE_OK\n")

    def test_cloud_dependency_current(self) -> None:
        result = self.run_bash('parse_dependency "$1" "$2"', META, f"{TARGET} (= {PKG_VERSION})")
        self.assertEqual(result.stdout, f"{TARGET}\t{ABI}\t{PKG_VERSION}\n")

    def test_dependency_versions_are_not_hardcoded(self) -> None:
        cases = [
            (META, "6.12.999+deb13.9-cloud-amd64", "6.12.999-12"),
            (META, "6.19.3+deb13.5-cloud-amd64", "1:6.19.3-2~deb13u1"),
            ("linux-image-amd64", "6.12.0-99-amd64", "6.12.0-99"),
            ("linux-image-amd64", "6.12.999+deb13.9-amd64", "6.12.999-12"),
        ]
        for meta, abi, version in cases:
            with self.subTest(abi=abi):
                result = self.run_bash('parse_dependency "$1" "$2"', meta, f"linux-image-{abi} (= {version})")
                self.assertEqual(result.stdout, f"linux-image-{abi}\t{abi}\t{version}\n")

    def test_dependency_rejects_wrong_family_and_unknown_structure(self) -> None:
        bad = [
            f"{TARGET}", f"{TARGET} (>= {PKG_VERSION})",
            f"{TARGET} (= {PKG_VERSION}), unrelated", f"{TARGET} (= {PKG_VERSION}) | other",
            "linux-image-6.12.115+deb13.1-amd64 (= 6.12.115-2)",
            "linux-image-6.12.115-rt-cloud-amd64 (= 6.12.115-2)",
            f"{TARGET} (= $(touch /tmp/never))",
        ]
        for dep in bad:
            with self.subTest(dep=dep):
                self.assertNotEqual(self.run_bash('parse_dependency "$1" "$2"', META, dep, check=False).returncode, 0)

    def test_abi_rejects_other_meta_and_realtime(self) -> None:
        for meta, abi in [
            ("linux-image-amd64", ABI), (META, "6.12.0-9-amd64"),
            ("linux-image-rt-amd64", "6.12.0-9-rt-amd64"),
            ("linux-image-amd64", "6.12.0-9-rt-amd64"),
            (META, "6.12-cloud-amd64"),
        ]:
            with self.subTest(meta=meta, abi=abi):
                self.assertNotEqual(self.run_bash('abi_ok "$1" "$2"', meta, abi, check=False).returncode, 0)

    def test_select_old_dynamic_inventory(self) -> None:
        inv = inventory(row(OLD1, "6.12.107-1"), row(OLD2, "6.12.113-1"))
        result = self.run_bash('select_old "$1" "$2" "$3" "$4"', META, TARGET, PKG_VERSION, inv)
        self.assertEqual(result.stdout.splitlines(), [OLD1, OLD2])

    def test_select_old_already_removed_and_config_only(self) -> None:
        for inv, expected in [
            (inventory(), []),
            (inventory(row(OLD2, "6.12.113-1")), [OLD2]),
            (inventory(row(OLD1, "6.12.107-1", "config-files")), [OLD1]),
        ]:
            with self.subTest(inv=inv):
                result = self.run_bash('select_old "$1" "$2" "$3" "$4"', META, TARGET, PKG_VERSION, inv)
                self.assertEqual(result.stdout.splitlines(), expected)

    def test_select_old_uses_debian_versions_not_abi_lexicographic_order(self) -> None:
        inv = inventory(row("linux-image-6.12.999+deb13-cloud-amd64", "6.12.115-2~rc1"))
        result = self.run_bash('select_old "$1" "$2" "$3" "$4"', META, TARGET, PKG_VERSION, inv)
        self.assertEqual(result.stdout.strip(), "linux-image-6.12.999+deb13-cloud-amd64")

    def test_select_old_rejects_unsafe_inventory(self) -> None:
        cases = {
            "newer": inventory(row("linux-image-6.12.116+deb13-cloud-amd64", "6.12.116-1")),
            "equal-version-different-abi": inventory(row(OLD1, PKG_VERSION)),
            "custom-maintainer": inventory(row(OLD1, "6.12.107-1", maintainer="Private builder")),
            "mixed-meta": inventory(row("linux-image-amd64", PKG_VERSION)),
            "wrong-family": inventory(row("linux-image-6.12.107+deb13-amd64", "6.12.107-1")),
            "unknown-family": inventory(row("linux-image-custom", "6.12.107-1")),
            "missing-meta": row(TARGET, PKG_VERSION),
            "missing-target": row(META, PKG_VERSION),
            "wrong-target-version": "\n".join((row(META, PKG_VERSION), row(TARGET, "6.12.115-1"))),
            "meta-config-only": "\n".join((row(META, PKG_VERSION, "config-files"), row(TARGET, PKG_VERSION))),
            "target-config-only": "\n".join((row(META, PKG_VERSION), row(TARGET, PKG_VERSION, "config-files"))),
        }
        for label, inv in cases.items():
            with self.subTest(label=label):
                result = self.run_bash('select_old "$1" "$2" "$3" "$4"', META, TARGET, PKG_VERSION, inv, check=False)
                self.assertNotEqual(result.returncode, 0)

    def test_purge_plan_exact_expected_packages(self) -> None:
        expected = f"{OLD1}\n{OLD2}"
        plan = f"Reading package lists... Done\nPurg {OLD1} [6.12.107-1]\nPurg {OLD2}:amd64 [6.12.113-1]"
        self.run_bash('validate_purge_plan "$1" "$2"', plan, expected)

    def test_purge_plan_rejects_extra_missing_duplicate_or_nonpurge_actions(self) -> None:
        base = f"Purg {OLD1} [6.12.107-1]"
        bad = [
            "", f"{base}\nPurg fail2ban [1.1.0]", f"{base}\n{base}",
            f"{base}\nPurg {TARGET} [{PKG_VERSION}]", f"{base}\nPurg {META} [{PKG_VERSION}]",
            f"{base}\nInst curl (8.0)", f"{base}\nConf curl (8.0)",
            f"Remv {OLD1} [6.12.107-1]",
        ]
        for plan in bad:
            with self.subTest(plan=plan):
                self.assertNotEqual(self.run_bash('validate_purge_plan "$1" "$2"', plan, OLD1, check=False).returncode, 0)
        self.assertNotEqual(self.run_bash('validate_purge_plan "$1" "$2"', base, f"{OLD1}\n{OLD2}", check=False).returncode, 0)

    def test_install_plan_rejects_removal(self) -> None:
        self.run_bash('validate_install_plan "$1"', f"Inst {TARGET} ({PKG_VERSION})\nConf {META} ({PKG_VERSION})")
        for plan in [f"Remv {OLD1} [6.12.107-1]", "Purg fail2ban [1.1.0]"]:
            self.assertNotEqual(self.run_bash('validate_install_plan "$1"', plan, check=False).returncode, 0)

    def test_actual_apt_protocol_accepts_only_frozen_remove_manifest(self) -> None:
        expected = f"{OLD1}\t6.12.107-1\n{OLD2}\t6.12.113-1"
        protocol = (
            "VERSION 2\nAPT::Architecture=amd64\nDPkg::Options::=--force-confold\n\n"
            f"{OLD1} 6.12.107-1 > - **REMOVE**\n"
            f"{OLD2} 6.12.113-1 > - **REMOVE**\n"
        )
        self.run_bash('printf "%s" "$2" | validate_purge_protocol "$1"', expected, protocol)

    def test_actual_apt_protocol_rejects_other_transactions(self) -> None:
        expected = f"{OLD1}\t6.12.107-1"
        header = "VERSION 2\nAPT::Architecture=amd64\n\n"
        removal = f"{OLD1} 6.12.107-1 > - **REMOVE**\n"
        bad = {
            "extra-business-package": header + removal + "fail2ban 1.1.0 > - **REMOVE**\n",
            "running-target": header + removal + f"{TARGET} {PKG_VERSION} > - **REMOVE**\n",
            "configure": header + f"{OLD1} 6.12.107-1 = 6.12.107-1 **CONFIGURE**\n",
            "upgrade": header + f"{OLD1} 6.12.107-1 < 6.12.107-2 /tmp/kernel.deb\n",
            "version-drift": header + f"{OLD1} 6.12.107-2 > - **REMOVE**\n",
            "duplicate": header + removal + removal,
            "missing": header,
            "old-protocol": "VERSION 1\n\n" + removal,
            "missing-header-boundary": "VERSION 2\nAPT::Architecture=amd64\n" + removal,
            "missing-config-equals": "VERSION 2\ninvalid-header\n\n" + removal,
            "trailing-action-field": header + removal.rstrip() + " unexpected\n",
            "wrong-direction": header + f"{OLD1} 6.12.107-1 < - **REMOVE**\n",
        }
        for label, protocol in bad.items():
            with self.subTest(label=label):
                proc = self.run_bash('printf "%s" "$2" | validate_purge_protocol "$1"', expected, protocol, check=False)
                self.assertNotEqual(proc.returncode, 0)

    def test_actual_apt_protocol_rejects_bad_manifest(self) -> None:
        protocol = f"VERSION 2\n\n{OLD1} 6.12.107-1 > - **REMOVE**\n"
        for expected in [
            f"{OLD1}\t6.12.107-1\n{OLD1}\t6.12.107-1", "fail2ban\t1.1.0", "",
        ]:
            with self.subTest(expected=expected):
                self.assertNotEqual(self.run_bash('printf "%s" "$2" | validate_purge_protocol "$1"', expected, protocol, check=False).returncode, 0)

    def test_actual_apt_protocol_accepts_complete_action_without_trailing_newline(self) -> None:
        expected = f"{OLD1}\t6.12.107-1"
        protocol = f"VERSION 2\n\n{OLD1} 6.12.107-1 > - **REMOVE**"
        self.run_bash('printf "%s" "$2" | validate_purge_protocol "$1"', expected, protocol)

    def test_actual_apt_protocol_rejects_unterminated_extra_business_action(self) -> None:
        expected = f"{OLD1}\t6.12.107-1"
        protocol = f"VERSION 2\n\n{OLD1} 6.12.107-1 > - **REMOVE**\nfail2ban 1.1.0 > - **REMOVE**"
        proc = self.run_bash('printf "%s" "$2" | validate_purge_protocol "$1"', expected, protocol, check=False)
        self.assertNotEqual(proc.returncode, 0)

    def test_same_abi_still_requires_a_different_boot(self) -> None:
        self.run_bash('boot_ready "$1" "$2" "$3" "$4"', BEFORE, AFTER, ABI, ABI)
        for before, after, target, running in [
            (BEFORE, BEFORE, ABI, ABI), (BEFORE, AFTER, ABI, "6.12.113+deb13-cloud-amd64"),
            ("bad", AFTER, ABI, ABI), (BEFORE, "bad", ABI, ABI),
        ]:
            with self.subTest(before=before, after=after, running=running):
                self.assertNotEqual(self.run_bash('boot_ready "$1" "$2" "$3" "$4"', before, after, target, running, check=False).returncode, 0)

    def test_initial_pending_state_is_valid(self) -> None:
        self.run_bash(assignments(valid_state()) + "\nvalidate_state")

    def test_verified_complete_state_is_valid(self) -> None:
        state = valid_state()
        state.update({
            "phase": "done", "result_status": "complete", "meta_version": PKG_VERSION,
            "target_pkg": TARGET, "target_abi": ABI, "target_version": PKG_VERSION,
            "verified_boot": AFTER, "reboots": "1", "verified_at": "1793792000",
            "removed": OLD1 + "," + OLD2,
        })
        self.run_bash(assignments(state) + "\nvalidate_state")

    def test_complete_state_cannot_have_failed_or_missing_reboot(self) -> None:
        for changes in [
            {"result_status": "complete"}, {"phase": "done", "result_status": "complete", "failed": "yes"},
            {"phase": "purge", "target_pkg": TARGET, "target_abi": ABI, "target_version": PKG_VERSION, "reboots": "0"},
        ]:
            with self.subTest(changes=changes):
                state = self.purge_state()
                state.update(changes)
                self.assertNotEqual(self.run_bash(assignments(state) + "\nvalidate_state", check=False).returncode, 0)

    def test_state_parser_rejects_duplicate_unknown_nul_missing_and_control_fields(self) -> None:
        text = "".join(f"{k}\t{v}\n" for k, v in valid_state().items())
        fixtures = {
            "duplicate": text + "phase\tinstall\n", "unknown": text + "injected\tyes\n",
            "nul": text.encode() + b"\0", "missing": text.replace("format\t1\n", ""),
            "control": text.replace("phase\tinstall", "phase\tinstall\r"),
            "source-injection": text.replace("phase\tinstall", "phase\t$(touch bad)"),
        }
        for label, content in fixtures.items():
            with self.subTest(label=label):
                path = self.root / (label + ".tsv")
                path.write_bytes(content.encode() if isinstance(content, str) else content)
                result = self.run_bash('plain_file() { [[ -f $1 && ! -L $1 ]]; }; load_state "$1"', str(path), check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "bad").exists())

    def test_state_parser_accepts_valid_pending_data_without_execution(self) -> None:
        path = self.root / "valid.tsv"
        path.write_text("".join(f"{k}\t{v}\n" for k, v in valid_state().items()), encoding="utf-8")
        self.run_bash('plain_file() { [[ -f $1 && ! -L $1 ]]; }; load_state "$1"; [[ ${S[phase]} == install ]]', str(path))

    def test_purge_verification_failure_never_reaches_apt(self) -> None:
        body = assignments(valid_state()) + r'''
verify_target() { die 'mock verification failed'; }
apt_run() { printf '%s\n' "$*" >> "$CALLS"; return 0; }
purge_old
'''
        result = self.run_bash(body, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_purge_unexpected_business_dependency_prevents_real_operation(self) -> None:
        inv = inventory(row(OLD1, "6.12.107-1"))
        state = valid_state()
        state.update({"target_pkg": TARGET, "target_abi": ABI, "target_version": PKG_VERSION})
        body = assignments(state) + "\n" + f"inventory() {{ printf '%s\\n' {shlex.quote(inv)}; }}\n" + r'''
verify_target() { :; }
apt_run() {
    printf '%s\n' "$*" >> "$CALLS"
    if [[ " $* " == *' -s '* ]]; then
        printf 'Purg %s [6.12.107-1]\nPurg fail2ban [1.1.0]\n' 'linux-image-6.12.107+deb13-cloud-amd64'
        return 0
    fi
    return 96
}
purge_old
'''
        result = self.run_bash(body, check=False)
        self.assertNotEqual(result.returncode, 0)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].startswith("-s purge "))

    def purge_state(self) -> dict[str, str]:
        state = valid_state()
        state.update({
            "phase": "purge", "meta_version": PKG_VERSION, "target_pkg": TARGET,
            "target_abi": ABI, "target_version": PKG_VERSION, "reboots": "1",
        })
        return state

    def purge_sandbox(self, before: str, plan: str) -> str:
        return (
            assignments(self.purge_state()) + "\n"
            + f"BEFORE_INVENTORY={shlex.quote(before)}\n"
            + f"AFTER_INVENTORY={shlex.quote(inventory())}\n"
            + f"SIM_PLAN={shlex.quote(plan)}\n"
            + f"MOCK_BOOT={shlex.quote(AFTER)}\n"
            + r'''
mkdir -p "$BASE"
verify_target() { printf 'verify\n' >> "$CALLS"; }
inventory() {
    if [[ -e $FIXTURE_ROOT/purged ]]; then printf '%s\n' "$AFTER_INVENTORY"
    else printf '%s\n' "$BEFORE_INVENTORY"; fi
}
dpkg-query() {
    local pkg=${!#}
    case "$*" in
        *'${Version}'*)
            case $pkg in
                linux-image-6.12.107+deb13-cloud-amd64) printf '6.12.107-1' ;;
                linux-image-6.12.113+deb13-cloud-amd64) printf '6.12.113-1' ;;
                *) return 95 ;;
            esac ;;
        *'${db:Status-Status}'*)
            [[ ! -e $FIXTURE_ROOT/purged ]] || return 1
            printf 'installed' ;;
        *) return 95 ;;
    esac
}
apt_run() {
    printf 'apt:%s\n' "$*" >> "$CALLS"
    if [[ " $* " == *' -s '* ]]; then printf '%s\n' "$SIM_PLAN"; return 0; fi
    if [[ " $* " == *' -y purge '* ]]; then : > "$FIXTURE_ROOT/purged"; return 0; fi
    return 94
}
save_state() { printf 'state:%s:%s\n' "${S[phase]}" "${S[result_status]}" >> "$CALLS"; }
save_to() { printf 'receipt:%s:%s\n' "${S[phase]}" "${S[result_status]}" >> "$CALLS"; }
boot_id() { printf '%s\n' "$MOCK_BOOT"; }
'''
        )

    def test_purge_success_uses_exact_selectors_and_reaches_cleanup(self) -> None:
        before = inventory(row(OLD1, "6.12.107-1"), row(OLD2, "6.12.113-1"))
        plan = f"Purg {OLD1} [6.12.107-1]\nPurg {OLD2} [6.12.113-1]"
        body = self.purge_sandbox(before, plan) + r'''
purge_old
[[ ${S[phase]} == cleanup && ${S[result_status]} == cleanup_pending ]]
[[ ${S[verified_boot]} == "$MOCK_BOOT" && ${S[purge_sha]} =~ ^[a-f0-9]{64}$ ]]
printf 'REMOVED:%s\n' "${S[removed]}"
'''
        proc = self.run_bash(body)
        self.assertIn(f"REMOVED:{OLD1},{OLD2}", proc.stdout)
        calls = self.calls.read_text().splitlines()
        actual = [line for line in calls if line.startswith("apt:") and " -y purge " in line]
        self.assertEqual(len(actual), 1)
        self.assertIn(f"?exact-name({OLD1})", actual[0])
        self.assertIn(f"?exact-name({OLD2})", actual[0])
        self.assertIn("--apt-guard", actual[0])

    def test_purge_without_old_images_never_calls_apt(self) -> None:
        proc = self.run_bash(self.purge_sandbox(inventory(), "") + r'''
purge_old
[[ ${S[phase]} == cleanup && ${S[result_status]} == cleanup_pending && ${S[removed]} == - ]]
''')
        self.assertEqual(proc.returncode, 0)
        self.assertFalse(any(line.startswith("apt:") for line in self.calls.read_text().splitlines()))

    def test_purge_resumes_after_previous_old_image_already_disappeared(self) -> None:
        before = inventory(row(OLD2, "6.12.113-1"))
        proc = self.run_bash(self.purge_sandbox(before, f"Purg {OLD2} [6.12.113-1]") + r'''
purge_old
printf '%s\n' "${S[removed]}"
''')
        self.assertIn(OLD2, proc.stdout)
        actual = [line for line in self.calls.read_text().splitlines() if line.startswith("apt:") and " -y purge " in line]
        self.assertEqual(len(actual), 1)
        self.assertNotIn(OLD1, actual[0])

    def test_purge_failure_does_not_declare_cleanup_or_complete(self) -> None:
        before = inventory(row(OLD1, "6.12.107-1"))
        body = self.purge_sandbox(before, f"Purg {OLD1} [6.12.107-1]") + r'''
apt_run() {
    printf 'apt:%s\n' "$*" >> "$CALLS"
    if [[ " $* " == *' -s '* ]]; then printf '%s\n' "$SIM_PLAN"; return 0; fi
    return 42
}
purge_old
printf 'SHOULD_NOT_COMPLETE\n'
'''
        proc = self.run_bash(body, check=False)
        self.assertEqual(proc.returncode, 42)
        self.assertNotIn("SHOULD_NOT_COMPLETE", proc.stdout)
        calls = self.calls.read_text()
        self.assertNotIn("cleanup_pending", calls)
        self.assertNotIn("receipt:", calls)

    def test_purge_inventory_change_after_simulation_blocks_actual_operation(self) -> None:
        before = inventory(row(OLD1, "6.12.107-1"))
        body = self.purge_sandbox(before, f"Purg {OLD1} [6.12.107-1]") + r'''
verify_target() {
    printf 'verify\n' >> "$CALLS"
    if [[ -e $FIXTURE_ROOT/verified-once ]]; then : > "$FIXTURE_ROOT/purged"
    else : > "$FIXTURE_ROOT/verified-once"; fi
}
purge_old
'''
        proc = self.run_bash(body, check=False)
        self.assertNotEqual(proc.returncode, 0)
        actual = [line for line in self.calls.read_text().splitlines() if line.startswith("apt:") and " -y purge " in line]
        self.assertEqual(actual, [])

    def temporary_file_checks(self) -> str:
        return r'''
plain_file() { [[ $1 == "$FIXTURE_ROOT"/* && -f $1 && ! -L $1 ]]; }
safe_dir() { [[ ( $1 == "$FIXTURE_ROOT" || $1 == "$FIXTURE_ROOT"/* ) && -d $1 && ! -L $1 ]]; }
'''

    def test_atomic_save_preserves_previous_state_on_precommit_failure(self) -> None:
        for failure in ("serialize_state", "chmod", "sync", "mv"):
            with self.subTest(failure=failure):
                task = self.root / "task"
                task.mkdir(exist_ok=True)
                state_path = task / "state.tsv"
                state_path.write_text("previous-valid-state\n", encoding="utf-8")
                body = (
                    assignments(valid_state()) + self.temporary_file_checks()
                    + f"\n{failure}() {{ return 73; }}\nsave_to \"$STATE\"\n"
                )
                proc = self.run_bash(body, check=False)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(state_path.read_text(), "previous-valid-state\n")
                self.assertEqual(list(task.glob(".kernel-update.*")), [])

    def test_atomic_save_writes_complete_reparseable_private_state(self) -> None:
        task = self.root / "task"
        task.mkdir()
        proc = self.run_bash(assignments(valid_state()) + self.temporary_file_checks() + r'''
save_to "$STATE"
load_state "$STATE"
[[ ${S[phase]} == install && ${S[entry_id]} == 2049:123 ]]
''')
        self.assertEqual(proc.returncode, 0)
        state_path = task / "state.tsv"
        actual = dict(line.split("\t", 1) for line in state_path.read_text().splitlines())
        self.assertEqual(actual, valid_state())
        self.assertEqual(state_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(task.glob(".kernel-update.*")), [])

    def cleanup_state(self) -> dict[str, str]:
        state = self.purge_state()
        state.update({
            "phase": "cleanup", "result_status": "cleanup_pending",
            "verified_boot": AFTER, "verified_at": "1793792000",
        })
        return state

    def test_cleanup_rejects_old_kernel_appearing_before_deleting_task_files(self) -> None:
        task = self.root / "task"
        task.mkdir()
        sentinel = task / "sentinel"
        sentinel.write_text("must remain", encoding="utf-8")
        inv = inventory(row(OLD1, "6.12.107-1"))
        body = (
            assignments(self.cleanup_state()) + "\n"
            + f"inventory() {{ printf '%s\\n' {shlex.quote(inv)}; }}\n"
            + r'''
verify_target() { :; }
verify_owned() { :; }
save_to() { printf 'save-called\n' >> "$CALLS"; }
apt_run() { printf 'apt-called\n' >> "$CALLS"; }
cleanup
'''
        )
        proc = self.run_bash(body, check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.calls.exists())
        self.assertEqual(sentinel.read_text(), "must remain")

    def resume_fixture(self, cleanup_receipt: bool = False, extra_residual: bool = False) -> tuple[Path, str]:
        task = self.root / "task"
        task.mkdir(mode=0o700)
        (task / "worker.sh").write_text("#!/bin/bash\n# retained identical worker\n", encoding="utf-8")
        (task / "owner").write_text(BEFORE + "\n", encoding="utf-8")
        (task / "run.log").write_text("retained task log\n", encoding="utf-8")
        if extra_residual:
            (task / "unknown-user-file").write_text("do not adopt or delete", encoding="utf-8")
        import hashlib
        state = self.cleanup_state() if cleanup_receipt else self.purge_state()
        state.update({"failed": "yes", "script_sha": hashlib.sha256((task / "worker.sh").read_bytes()).hexdigest()})
        destination = self.root / "result.tsv" if cleanup_receipt else task / "state.tsv"
        destination.write_text("".join(f"{k}\t{v}\n" for k, v in state.items()), encoding="utf-8")
        body = self.temporary_file_checks() + r'''
cat() {
    if [[ ${1:-} == /etc/machine-id ]]; then printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    else /bin/cat "$@"; fi
}
safe_entry() { [[ $1 == /root/next-vps-kernel-update.sh ]]; }
sha() {
    if [[ $1 == /root/next-vps-kernel-update.sh ]]; then sha256sum -- "$WORKER" | awk '{print $1}'
    else sha256sum -- "$1" | awk '{print $1}'; fi
}
identity() {
    if [[ $1 == /root/next-vps-kernel-update.sh ]]; then printf '2049:999\n'
    else stat -c '%d:%i' -- "$1"; fi
}
launch() { printf 'launch:%s:%s\n' "${S[entry_id]}" "${S[failed]}" >> "$CALLS"; }
'''
        return destination, body

    def test_resume_adopts_reuploaded_identical_payload_new_inode(self) -> None:
        destination, body = self.resume_fixture()
        self.run_bash(body + '\nresume_task /root/next-vps-kernel-update.sh\n')
        saved = dict(line.split("\t", 1) for line in destination.read_text().splitlines())
        self.assertEqual(saved["entry_id"], "2049:999")
        self.assertEqual(saved["failed"], "no")
        self.assertEqual(self.calls.read_text(), "launch:2049:999:no\n")
        self.assertTrue((self.root / "unit.service").exists())

    def test_cleanup_receipt_resume_recreates_state_with_new_entry_inode(self) -> None:
        _, body = self.resume_fixture(cleanup_receipt=True)
        self.run_bash(body + '\nresume_task /root/next-vps-kernel-update.sh\n')
        saved = dict(line.split("\t", 1) for line in (self.root / "task/state.tsv").read_text().splitlines())
        self.assertEqual(saved["phase"], "cleanup")
        self.assertEqual(saved["result_status"], "cleanup_pending")
        self.assertEqual(saved["entry_id"], "2049:999")
        self.assertEqual(saved["failed"], "no")

    def test_resume_rejects_reuploaded_different_payload(self) -> None:
        destination, body = self.resume_fixture()
        before = destination.read_bytes()
        body += r'''
sha() { printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n'; }
resume_task /root/next-vps-kernel-update.sh
'''
        proc = self.run_bash(body, check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.calls.exists())
        self.assertEqual(destination.read_bytes(), before)

    def test_cleanup_receipt_resume_rejects_unknown_residual(self) -> None:
        _, body = self.resume_fixture(cleanup_receipt=True, extra_residual=True)
        proc = self.run_bash(body + '\nresume_task /root/next-vps-kernel-update.sh\n', check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.calls.exists())
        self.assertEqual((self.root / "task/unknown-user-file").read_text(), "do not adopt or delete")

    def prepare_fixture(self) -> tuple[Path, str, str]:
        old = self.cleanup_state()
        old.update({"phase": "done", "result_status": "complete", "task_id": "33333333-3333-4333-8333-333333333333"})
        result_path = self.root / "result.tsv"
        result_path.write_text("".join(f"{k}\t{v}\n" for k, v in old.items()), encoding="utf-8")
        random_dir = self.root / "proc/sys/kernel/random"
        random_dir.mkdir(parents=True)
        new_task = "44444444-4444-4444-8444-444444444444"
        (random_dir / "uuid").write_text(new_task + "\n", encoding="utf-8")
        (random_dir / "boot_id").write_text(BEFORE + "\n", encoding="utf-8")
        (self.root / "uploaded.sh").write_text("#!/bin/bash\n# new task payload\n", encoding="utf-8")
        body = self.temporary_file_checks() + r'''
cat() {
    if [[ ${1:-} == /etc/machine-id ]]; then printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    else /bin/cat "$@"; fi
}
safe_entry() { [[ $1 == /root/next-vps-kernel-update.sh ]]; }
sha() {
    if [[ $1 == /root/next-vps-kernel-update.sh ]]; then sha256sum -- "$FIXTURE_ROOT/uploaded.sh" | awk '{print $1}'
    else sha256sum -- "$1" | awk '{print $1}'; fi
}
identity() {
    if [[ $1 == /root/next-vps-kernel-update.sh ]]; then stat -c '%d:%i' -- "$FIXTURE_ROOT/uploaded.sh"
    else stat -c '%d:%i' -- "$1"; fi
}
snapshot() {
    S[config_sha]=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    S[ssh_sha]=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    S[swap_sha]=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    S[swappiness]=10
    S[balloon]=module
}
cp() {
    [[ $# == 3 && $1 == -- && $2 == /root/next-vps-kernel-update.sh && $3 == "$BASE"/.bootstrap-worker.* ]] || return 95
    [[ -f $STATE && $(receipt_field "$STATE" task_id) == "${S[task_id]}" ]] || return 96
    /bin/cp -- "$FIXTURE_ROOT/uploaded.sh" "$3"
}
publish_login_notice() { printf 'notice:%s\n' "$1" >> "$CALLS"; }
launch() {
    [[ $(receipt_field "$RESULT" task_id) == "${S[task_id]}" ]]
    [[ $(receipt_field "$RESULT" phase) == install ]]
    [[ $(receipt_field "$RESULT" result_status) == running ]]
    [[ $(receipt_field "$RESULT" failed) == no ]]
    printf 'launch:%s\n' "${S[task_id]}" >> "$CALLS"
}
'''
        return result_path, new_task, body

    def test_prepare_publishes_new_running_receipt_before_launch(self) -> None:
        result_path, new_task, body = self.prepare_fixture()
        body += "\nprepare /root/next-vps-kernel-update.sh linux-image-cloud-amd64\n"
        self.run_bash(body)
        saved = dict(line.split("\t", 1) for line in result_path.read_text().splitlines())
        self.assertEqual(saved["task_id"], new_task)
        self.assertEqual(saved["result_status"], "running")
        self.assertEqual(saved["phase"], "install")
        self.assertEqual(saved["failed"], "no")
        self.assertEqual(self.calls.read_text(), f"launch:{new_task}\n")

    def test_prepare_copy_failure_keeps_durable_failure_and_resumes_without_partial_worker(self) -> None:
        result_path, task_id, body = self.prepare_fixture()
        proc = self.run_bash(body + r'''
cp() { printf 'partial worker\n' > "$3"; return 73; }
prepare /root/next-vps-kernel-update.sh linux-image-cloud-amd64
''', check=False)
        self.assertNotEqual(proc.returncode, 0)
        task = self.root / "task"
        self.assertFalse((task / "worker.sh").exists())
        self.assertEqual(list(task.glob(".bootstrap-*")), [])
        for path in (task / "state.tsv", result_path):
            saved = dict(line.split("\t", 1) for line in path.read_text().splitlines())
            self.assertEqual(saved["task_id"], task_id)
            self.assertEqual(saved["phase"], "install")
            self.assertEqual(saved["failed"], "yes")
            self.assertEqual(saved["result_status"], "running")
        self.assertFalse((self.root / "unit.service").exists())
        self.assertEqual(self.calls.read_text(), "notice:failure\n")
        self.run_bash(body + "\nresume_task /root/next-vps-kernel-update.sh\n")
        self.assertEqual((task / "worker.sh").read_bytes(), (self.root / "uploaded.sh").read_bytes())
        saved = dict(line.split("\t", 1) for line in result_path.read_text().splitlines())
        # The fixture launch checks RESULT; resume must refresh failure before handoff.
        self.assertEqual(saved["failed"], "no")

    def test_prepare_mkdir_failure_does_not_leave_stale_success_and_can_resume(self) -> None:
        result_path, task_id, body = self.prepare_fixture()
        proc = self.run_bash(body + r'''
mkdir() { return 73; }
prepare /root/next-vps-kernel-update.sh linux-image-cloud-amd64
''', check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse((self.root / "task").exists())
        saved = dict(line.split("\t", 1) for line in result_path.read_text().splitlines())
        self.assertEqual(saved["task_id"], task_id)
        self.assertEqual(saved["failed"], "yes")
        self.assertEqual(saved["result_status"], "running")
        self.run_bash(body + "\nresume_task /root/next-vps-kernel-update.sh\n")
        self.assertTrue((self.root / "task/worker.sh").exists())

    def test_prepare_initial_state_failure_retains_owned_bootstrap_and_can_resume(self) -> None:
        result_path, _, body = self.prepare_fixture()
        proc = self.run_bash(body + r'''
save_state() { return 74; }
prepare /root/next-vps-kernel-update.sh linux-image-cloud-amd64
''', check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue((self.root / "task/owner").exists())
        self.assertFalse((self.root / "task/state.tsv").exists())
        self.assertFalse((self.root / "task/worker.sh").exists())
        self.assertFalse((self.root / "unit.service").exists())
        saved = dict(line.split("\t", 1) for line in result_path.read_text().splitlines())
        self.assertEqual(saved["failed"], "yes")
        self.run_bash(body + "\nresume_task /root/next-vps-kernel-update.sh\n")
        self.assertTrue((self.root / "task/state.tsv").exists())
        self.assertTrue((self.root / "task/worker.sh").exists())

    def test_prepare_owner_temp_failure_removes_only_its_empty_bootstrap_directory(self) -> None:
        _, _, body = self.prepare_fixture()
        proc = self.run_bash(body + r'''
mktemp() {
    [[ $1 != "$BASE"/.bootstrap-owner.* ]] || return 73
    command mktemp "$@"
}
prepare /root/next-vps-kernel-update.sh linux-image-cloud-amd64
''', check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse((self.root / "task").exists())
        self.run_bash(body + "\nresume_task /root/next-vps-kernel-update.sh\n")
        self.assertTrue((self.root / "task/worker.sh").exists())

    def test_prepare_unit_failure_preserves_identical_worker_for_resume(self) -> None:
        _, _, body = self.prepare_fixture()
        proc = self.run_bash(body + r'''
write_unit() { return 75; }
prepare /root/next-vps-kernel-update.sh linux-image-cloud-amd64
''', check=False)
        self.assertNotEqual(proc.returncode, 0)
        worker = self.root / "task/worker.sh"
        before = (worker.read_bytes(), worker.stat().st_ino)
        self.run_bash(body + "\nresume_task /root/next-vps-kernel-update.sh\n")
        self.assertEqual((worker.read_bytes(), worker.stat().st_ino), before)

    def test_bootstrap_resume_rejects_unowned_directory_unknown_file_or_changed_worker(self) -> None:
        _, _, body = self.prepare_fixture()
        self.run_bash(body + r'''
cp() { return 73; }
prepare /root/next-vps-kernel-update.sh linux-image-cloud-amd64
''', check=False)
        task = self.root / "task"
        owner = task / "owner"
        original_owner = owner.read_bytes()
        state_path = task / "state.tsv"
        state_before = (state_path.read_bytes(), state_path.stat().st_ino)
        owner.unlink()
        proc = self.run_bash(body + "\nresume_task /root/next-vps-kernel-update.sh\n", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(owner.exists())
        self.assertEqual((state_path.read_bytes(), state_path.stat().st_ino), state_before)
        owner.write_text("33333333-3333-4333-8333-333333333333\n")
        proc = self.run_bash(body + "\nresume_task /root/next-vps-kernel-update.sh\n", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual((state_path.read_bytes(), state_path.stat().st_ino), state_before)
        self.assertEqual(owner.read_text(), "33333333-3333-4333-8333-333333333333\n")
        owner.write_bytes(original_owner)
        unknown = task / "unknown-user-file"
        unknown.write_text("must remain")
        proc = self.run_bash(body + "\nresume_task /root/next-vps-kernel-update.sh\n", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(unknown.read_text(), "must remain")
        self.assertFalse((task / "worker.sh").exists())
        unknown.unlink()
        worker = task / "worker.sh"
        worker.write_text("changed worker must remain")
        proc = self.run_bash(body + "\nresume_task /root/next-vps-kernel-update.sh\n", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(worker.read_text(), "changed worker must remain")

    def test_worker_error_replaces_stale_success_receipt_with_current_failure(self) -> None:
        task = self.root / "task"
        task.mkdir(mode=0o700)
        state = self.purge_state()
        (task / "state.tsv").write_text("".join(f"{k}\t{v}\n" for k, v in state.items()), encoding="utf-8")
        (task / "owner").write_text(state["task_id"] + "\n", encoding="utf-8")
        old = self.cleanup_state()
        old.update({"phase": "done", "result_status": "complete", "task_id": "33333333-3333-4333-8333-333333333333"})
        result_path = self.root / "result.tsv"
        result_path.write_text("".join(f"{k}\t{v}\n" for k, v in old.items()), encoding="utf-8")
        proc = self.run_bash(assignments(state) + self.temporary_file_checks() + "\non_error 42\n", check=False)
        self.assertEqual(proc.returncode, 42)
        saved = dict(line.split("\t", 1) for line in result_path.read_text().splitlines())
        state_saved = dict(line.split("\t", 1) for line in (task / "state.tsv").read_text().splitlines())
        self.assertEqual(saved["task_id"], BEFORE)
        self.assertEqual(saved["result_status"], "running")
        self.assertEqual(saved["phase"], "purge")
        self.assertEqual(saved["failed"], "yes")
        self.assertEqual(state_saved, saved)

    def test_launch_start_failure_persists_failure_and_publishes_one_notice(self) -> None:
        task = self.root / "task"
        task.mkdir(mode=0o700)
        state = self.purge_state()
        state_path = task / "state.tsv"
        state_path.write_text("".join(f"{k}\t{v}\n" for k, v in state.items()), encoding="utf-8")
        (task / "owner").write_text(state["task_id"] + "\n", encoding="utf-8")
        body = assignments(state) + self.temporary_file_checks() + r'''
unit_content > "$UNIT_FILE"
chmod 0600 "$UNIT_FILE"
publish_login_notice() { printf 'notice:%s\n' "$1" >> "$CALLS"; }
nv_ui_heading() { :; }
nv_ui_launch() { printf 'UNEXPECTED_COMPLETION\n' >> "$CALLS"; }
systemctl() {
    printf 'service:%s\n' "$*" >> "$CALLS"
    case "$*" in
        *'FragmentPath'*) printf '%s\n' "$UNIT_FILE" ;;
        *'DropInPaths'*) printf '\n' ;;
        'start --no-block '*) return 41 ;;
        *) return 0 ;;
    esac
}
exec 9<"$FIXTURE_ROOT"
flock -n 9
launch
printf 'SHOULD_NOT_COMPLETE\n'
'''
        proc = self.run_bash(body, check=False)
        self.assertEqual(proc.returncode, 41, proc.stdout + proc.stderr)
        self.assertNotIn("SHOULD_NOT_COMPLETE", proc.stdout)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls.count("notice:failure"), 1)
        self.assertNotIn("UNEXPECTED_COMPLETION", calls)
        for path in (state_path, self.root / "result.tsv"):
            saved = dict(line.split("\t", 1) for line in path.read_text().splitlines())
            self.assertEqual(saved["task_id"], BEFORE)
            self.assertEqual(saved["phase"], "purge")
            self.assertEqual(saved["result_status"], "running")
            self.assertEqual(saved["failed"], "yes")

    def test_cleanup_resume_reconstructs_missing_worker_and_owner_with_state_retained(self) -> None:
        state_path, body = self.resume_fixture()
        state = self.cleanup_state()
        state.update({"failed": "yes"})
        task = self.root / "task"
        payload = (task / "worker.sh").read_bytes()
        import hashlib
        state["script_sha"] = hashlib.sha256(payload).hexdigest()
        state_path.write_text("".join(f"{k}\t{v}\n" for k, v in state.items()), encoding="utf-8")
        (self.root / "uploaded.sh").write_bytes(payload)
        (task / "worker.sh").unlink()
        (task / "owner").unlink()
        body += r'''
sha() {
    if [[ $1 == /root/next-vps-kernel-update.sh ]]; then sha256sum -- "$FIXTURE_ROOT/uploaded.sh" | awk '{print $1}'
    else sha256sum -- "$1" | awk '{print $1}'; fi
}
cp() {
    [[ $# == 3 && $1 == -- && $2 == /root/next-vps-kernel-update.sh && $3 == "$BASE"/.bootstrap-worker.* ]] || return 95
    /bin/cp -- "$FIXTURE_ROOT/uploaded.sh" "$3"
}
resume_task /root/next-vps-kernel-update.sh
'''
        self.run_bash(body)
        self.assertEqual((task / "worker.sh").read_bytes(), payload)
        self.assertEqual((task / "owner").read_text(), BEFORE + "\n")
        saved = dict(line.split("\t", 1) for line in state_path.read_text().splitlines())
        self.assertEqual(saved["phase"], "cleanup")
        self.assertEqual(saved["result_status"], "cleanup_pending")
        self.assertEqual(saved["failed"], "no")
        self.assertEqual(saved["entry_id"], "2049:999")
        self.assertEqual(self.calls.read_text(), "launch:2049:999:no\n")

    def test_cleanup_failure_after_state_deletion_replaces_completion_and_notifies(self) -> None:
        state = self.cleanup_state()
        state.update({"phase": "done", "result_status": "complete"})
        result_path = self.root / "result.tsv"
        result_path.write_text("".join(f"{k}\t{v}\n" for k, v in state.items()), encoding="utf-8")
        body = assignments(state) + self.temporary_file_checks() + r'''
publish_login_notice() { printf 'notice:%s\n' "$1" >> "$CALLS"; }
nv_ui_heading() { :; }
on_error 45
'''
        proc = self.run_bash(body, check=False)
        self.assertEqual(proc.returncode, 45)
        self.assertFalse((self.root / "task/state.tsv").exists())
        saved = dict(line.split("\t", 1) for line in result_path.read_text().splitlines())
        self.assertEqual(saved["phase"], "cleanup")
        self.assertEqual(saved["result_status"], "cleanup_pending")
        self.assertEqual(saved["failed"], "yes")
        self.assertEqual(self.calls.read_text(), "notice:failure\n")

    def worker_sandbox(self, phase: str, reboots: str, boot: str, running: str = ABI) -> str:
        state = self.purge_state()
        state.update({"phase": phase, "reboots": reboots})
        return (
            assignments(state) + "\n"
            + f"MOCK_BOOT={shlex.quote(boot)}\nMOCK_RUNNING={shlex.quote(running)}\n"
            + r'''
WORKER=$0
load_state() { :; }
cat() {
    if [[ ${1:-} == /etc/machine-id ]]; then printf '%s\n' "${S[machine_id]}"
    else /bin/cat "$@"; fi
}
check_os() { :; }
verify_owned() { :; }
note() { :; }
boot_id() { printf '%s\n' "$MOCK_BOOT"; }
uname() { printf '%s\n' "$MOCK_RUNNING"; }
save_state() { printf 'state:%s:%s\n' "${S[phase]}" "${S[reboots]}" >> "$CALLS"; }
sync() { :; }
systemctl() { printf 'systemctl:%s\n' "$*" >> "$CALLS"; }
verify_target() {
    boot_ready "${S[boot_before]}" "$(boot_id)" "${S[target_abi]}" "$(uname -r)" || die 'mock wrong boot/kernel'
}
purge_old() { printf 'PURGE\n' >> "$CALLS"; S[phase]=cleanup; }
cleanup() { printf 'CLEANUP\n' >> "$CALLS"; }
'''
        )

    def test_worker_requests_one_reboot_and_does_not_continue_to_purge(self) -> None:
        self.run_bash(self.worker_sandbox("reboot", "0", BEFORE) + "\nworker")
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls.count("systemctl:reboot"), 1)
        self.assertNotIn("PURGE", calls)
        self.assertIn("state:reboot:1", calls)

    def test_worker_same_boot_does_not_request_another_reboot_or_purge(self) -> None:
        proc = self.run_bash(self.worker_sandbox("reboot", "1", BEFORE) + "\nworker", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_worker_new_boot_wrong_kernel_does_not_purge(self) -> None:
        proc = self.run_bash(self.worker_sandbox("reboot", "1", AFTER, "6.12.113+deb13-cloud-amd64") + "\nworker", check=False)
        self.assertNotEqual(proc.returncode, 0)
        calls = self.calls.read_text()
        self.assertNotIn("PURGE", calls)
        self.assertNotIn("systemctl:reboot", calls)

    def test_worker_verified_new_boot_advances_to_purge(self) -> None:
        self.run_bash(self.worker_sandbox("reboot", "1", AFTER) + "\nworker")
        calls = self.calls.read_text().splitlines()
        self.assertIn("PURGE", calls)
        self.assertIn("CLEANUP", calls)
        self.assertNotIn("systemctl:reboot", calls)

    def test_worker_does_not_automatically_retry_failed_task(self) -> None:
        proc = self.run_bash(self.worker_sandbox("reboot", "1", AFTER) + '\nS[failed]=yes\nworker', check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_worker_rejects_state_from_another_machine(self) -> None:
        body = self.worker_sandbox("reboot", "1", AFTER) + r'''
cat() {
    if [[ ${1:-} == /etc/machine-id ]]; then printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
    else /bin/cat "$@"; fi
}
worker
'''
        proc = self.run_bash(body, check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
