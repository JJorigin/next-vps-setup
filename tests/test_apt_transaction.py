"""Exercise the purge guard against real, rootless APT protocol-v2 output.

APT sees only synthetic package records in a TemporaryDirectory. Every APT
state/cache/config/log path is redirected there. A mandatory dpkg stub refuses
all package operations; the real dpkg is never used for installation/removal.
The production script is sourced only to call validate_purge_protocol.

Run in Linux/WSL as an ordinary user:
    python3 -m unittest discover -s tests -p test_apt_transaction.py -v
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


SCRIPT = Path(__file__).resolve().parents[1] / "next-vps-kernel-update.sh"
OLD = "linux-image-6.12.107+deb13-cloud-amd64"
OLD_VERSION = "6.12.107-1"
TARGET = "linux-image-6.12.115+deb13.1-cloud-amd64"
TARGET_VERSION = "6.12.115-2"
META = "linux-image-cloud-amd64"
BUSINESS = "synthetic-kernel-dependent-business"


def package_record(
    name: str, version: str, depends: str = "", status: str = "install ok installed",
) -> str:
    lines = [
        f"Package: {name}", f"Status: {status}", "Priority: optional",
        "Section: misc", "Installed-Size: 1",
        "Maintainer: Synthetic Test <test@example.invalid>", "Architecture: amd64",
        f"Version: {version}",
    ]
    if depends:
        lines.append(f"Depends: {depends}")
    lines.append("Description: Isolated protocol test fixture; not a system package.")
    return "\n".join(lines) + "\n\n"


@unittest.skipUnless(
    os.name == "posix" and shutil.which("apt-get") and shutil.which("apt-config")
    and shutil.which("bash"), "requires Linux/WSL with APT and Bash",
)
class AptTransactionProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("rootless test only; do not run this integration test as root")
        self.tmp = tempfile.TemporaryDirectory(prefix="next-kernel-apt-protocol-", dir="/tmp")
        self.root = Path(self.tmp.name).resolve()
        self.addCleanup(self.tmp.cleanup)
        self.assertEqual(self.root.parent, Path("/tmp"))
        self.assertEqual(self.root.stat().st_uid, os.geteuid())
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.apt_get = Path(shutil.which("apt-get")).resolve()
        self.apt_config = Path(shutil.which("apt-config")).resolve()
        self.capture = self.root / "protocol.txt"
        self.verdict = self.root / "guard-verdict.txt"
        self.info_fd = self.root / "info-fd.txt"
        self.dpkg_operations = self.root / "dpkg-operations.txt"
        self.dpkg_queries = self.root / "dpkg-queries.txt"
        self.status = self.root / "var/lib/dpkg/status"
        self.expected = self.root / "expected.tsv"
        self.wrapper = self.root / "guard.sh"
        self.stub = self.root / "deny-dpkg.sh"
        self.config = self.root / "apt.conf"

        for directory in (
            "etc/apt/apt.conf.d", "etc/apt/sources.list.d", "etc/apt/trusted.gpg.d",
            "var/lib/dpkg/updates", "var/lib/apt/lists/partial",
            "var/cache/apt/archives/partial", "var/log/apt", "dpkg-root",
        ):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        (self.root / "etc/apt/sources.list").write_text("", encoding="utf-8")
        (self.root / "etc/apt/empty.conf").write_text("", encoding="utf-8")
        (self.root / "var/lib/apt/extended_states").write_text("", encoding="utf-8")
        self.expected.write_text(f"{OLD}\t{OLD_VERSION}\n", encoding="utf-8")

        self.stub.write_text(
            "#!/bin/bash\nset -eu\n"
            f"printf '%s\\n' \"$*\" >> {shlex.quote(str(self.dpkg_queries))}\n"
            'case "${1:-}" in\n'
            '  --print-foreign-architectures) exit 0 ;;\n'
            '  --print-architecture) printf "amd64\\n"; exit 0 ;;\n'
            '  --version) printf "Debian dpkg synthetic-deny-stub version 1.22.6 (amd64).\\n"; exit 0 ;;\n'
            '  --assert-*) exit 0 ;;\n'
            'esac\n'
            f"printf '%s\\n' \"$*\" >> {shlex.quote(str(self.dpkg_operations))}\n"
            "printf '%s\\n' 'Synthetic dpkg refused operation (expected).' >&2\nexit 91\n",
            encoding="utf-8", newline="\n",
        )
        self.stub.chmod(0o700)
        self.wrapper.write_text(
            "#!/bin/bash\nset -Eeuo pipefail\n"
            '[[ $(id -u) != 0 && ${1:-} == --protocol-only ]] || exit 94\n'
            f"printf '%s\\n' \"${{APT_HOOK_INFO_FD:-missing}}\" > {shlex.quote(str(self.info_fd))}\n"
            f"cat > {shlex.quote(str(self.capture))}\n"
            f"source {shlex.quote(str(SCRIPT))}\n"
            f"expected=$(cat {shlex.quote(str(self.expected))})\n"
            f"if validate_purge_protocol \"$expected\" < {shlex.quote(str(self.capture))}; then\n"
            f"  printf 'accepted\\n' > {shlex.quote(str(self.verdict))}\n"
            "else\n"
            f"  printf 'rejected\\n' > {shlex.quote(str(self.verdict))}\n"
            "  exit 92\nfi\n",
            encoding="utf-8", newline="\n",
        )
        self.wrapper.chmod(0o700)

        paths = {
            "Dir": self.root,
            "Dir::Etc": self.root / "etc/apt",
            "Dir::Etc::main": self.root / "etc/apt/empty.conf",
            "Dir::Etc::parts": self.root / "etc/apt/apt.conf.d",
            "Dir::Etc::sourcelist": self.root / "etc/apt/sources.list",
            "Dir::Etc::sourceparts": self.root / "etc/apt/sources.list.d",
            "Dir::Etc::trusted": self.root / "etc/apt/trusted.gpg",
            "Dir::Etc::trustedparts": self.root / "etc/apt/trusted.gpg.d",
            "Dir::State": self.root / "var/lib/apt",
            "Dir::State::status": self.status,
            "Dir::State::lists": self.root / "var/lib/apt/lists",
            "Dir::State::extended_states": self.root / "var/lib/apt/extended_states",
            "Dir::Cache": self.root / "var/cache/apt",
            "Dir::Cache::archives": self.root / "var/cache/apt/archives",
            "Dir::Cache::pkgcache": self.root / "var/cache/apt/pkgcache.bin",
            "Dir::Cache::srcpkgcache": self.root / "var/cache/apt/srcpkgcache.bin",
            "Dir::Log": self.root / "var/log/apt",
            "Dir::Bin::dpkg": self.stub,
        }
        self.config.write_text(
            "\n".join(f'{key} "{value}";' for key, value in paths.items()) + "\n"
            'APT::Architecture "amd64";\nAPT::Architectures { "amd64"; };\n'
            'APT::Sandbox::User "";\nDebug::NoLocking "true";\n'
            'APT::Get::AutomaticRemove "false";\nAPT::Install-Recommends "false";\n'
            f'DPkg::Options {{ "--root={self.root / "dpkg-root"}"; "--admindir={self.status.parent}"; }};\n'
            f'DPkg::Pre-Install-Pkgs {{ "{self.wrapper} --protocol-only"; }};\n'
            f'DPkg::Tools::Options::{self.wrapper}::Version "2";\n'
            f'DPkg::Tools::Options::{self.wrapper}::InfoFD "0";\n',
            encoding="utf-8", newline="\n",
        )
        self.env = os.environ.copy()
        for key in tuple(self.env):
            if key.startswith("APT_") or key.startswith("DPKG_"):
                del self.env[key]
        self.env.update({"APT_CONFIG": str(self.config), "LC_ALL": "C", "PATH": "/usr/bin:/bin"})

    def write_inventory(
        self, *, dependent_business: bool = False, config_files: bool = False,
    ) -> bytes:
        contents = (
            package_record(
                OLD, OLD_VERSION,
                status="deinstall ok config-files" if config_files else "install ok installed",
            )
            + package_record(TARGET, TARGET_VERSION)
            + package_record(META, TARGET_VERSION, f"{TARGET} (= {TARGET_VERSION})")
        )
        if dependent_business:
            contents += package_record(BUSINESS, "1.0", OLD)
        self.status.write_text(contents, encoding="utf-8", newline="\n")
        return self.status.read_bytes()

    def run_apt(self) -> subprocess.CompletedProcess[str]:
        # Command-line setting reinforces the config: dpkg cannot point to the host binary.
        dump = subprocess.run(
            [str(self.apt_config), "dump"], env=self.env, cwd=self.root,
            text=True, capture_output=True, timeout=15, check=True,
        ).stdout
        for key in (
            "Dir::Etc", "Dir::Etc::parts", "Dir::Etc::sourcelist", "Dir::State::status",
            "Dir::State::lists", "Dir::State::extended_states", "Dir::Cache::archives",
            "Dir::Cache::pkgcache", "Dir::Cache::srcpkgcache", "Dir::Log", "Dir::Bin::dpkg",
        ):
            match = re.search(rf'^{re.escape(key)} "([^"]+)";', dump, re.MULTILINE)
            self.assertIsNotNone(match, (key, dump))
            self.assertTrue(Path(match.group(1)).is_relative_to(self.root), (key, match.group(1)))
        self.assertIn(f'Dir::Bin::dpkg "{self.stub}";', dump)
        self.assertEqual((self.root / "etc/apt/sources.list").read_text(), "")
        self.assertEqual(list((self.root / "etc/apt/sources.list.d").iterdir()), [])
        self.assertEqual(list((self.root / "etc/apt/apt.conf.d").iterdir()), [])
        return subprocess.run(
            [str(self.apt_get), "-o", f"Dir::Bin::dpkg={self.stub}",
             "-o", "Debug::NoLocking=true", "-o", "APT::Get::AutomaticRemove=false",
             "-y", "purge", f"?exact-name({OLD})"],
            env=self.env, cwd=self.root, text=True, capture_output=True, timeout=30,
        )

    def test_real_protocol_accepts_only_exact_old_kernel_and_version(self) -> None:
        before = self.write_inventory()
        proc = self.run_apt()
        self.assertEqual(self.verdict.read_text(), "accepted\n", proc.stdout + proc.stderr)
        self.assertEqual(self.info_fd.read_text(), "0\n")
        protocol = self.capture.read_text()
        self.assertTrue(protocol.startswith("VERSION 2\n"), protocol)
        records = protocol.split("\n\n", 1)[1].splitlines()
        self.assertEqual(records, [f"{OLD} {OLD_VERSION} > - **REMOVE**"])
        self.assertTrue(self.dpkg_operations.exists(), proc.stdout + proc.stderr)
        self.assertNotEqual(proc.returncode, 0, "mandatory dpkg deny-stub must prevent changes")
        self.assertIn("Synthetic dpkg refused operation", proc.stderr)
        self.assertEqual(self.status.read_bytes(), before)

    def test_real_protocol_rejects_collateral_business_removal_before_dpkg(self) -> None:
        before = self.write_inventory(dependent_business=True)
        proc = self.run_apt()
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(self.verdict.read_text(), "rejected\n", proc.stdout + proc.stderr)
        self.assertEqual(self.info_fd.read_text(), "0\n")
        protocol = self.capture.read_text()
        self.assertIn(f"{OLD} {OLD_VERSION} > - **REMOVE**", protocol)
        self.assertIn(f"{BUSINESS} 1.0 > - **REMOVE**", protocol)
        self.assertFalse(self.dpkg_operations.exists(), "dpkg must not run after guard rejection")
        self.assertEqual(self.status.read_bytes(), before)

    def test_real_protocol_accepts_config_files_package_version_without_mutation(self) -> None:
        before = self.write_inventory(config_files=True)
        proc = self.run_apt()
        self.assertNotEqual(proc.returncode, 0, "the guard or deny-stub must prevent changes")
        self.assertTrue(self.capture.exists(), proc.stdout + proc.stderr)
        self.assertEqual(self.info_fd.read_text(), "0\n")
        records = self.capture.read_text().split("\n\n", 1)[1].splitlines()
        self.assertEqual(records, [f"{OLD} {OLD_VERSION} > - **REMOVE**"])
        self.assertEqual(self.verdict.read_text(), "accepted\n", proc.stdout + proc.stderr)
        self.assertTrue(self.dpkg_operations.exists(), proc.stdout + proc.stderr)
        self.assertIn("Synthetic dpkg refused operation", proc.stderr)
        self.assertEqual(self.status.read_bytes(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
