"""Cleanup must retain the active oneshot's in-memory timeout until it exits.

Only extracted cleanup functions run against temporary files. The systemctl
stub models the regression: an implicit/explicit reload during self-removal
is rejected. No real systemd, APT or reboot is invoked.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

def extract(path, name):
    source = path.read_text(encoding="utf-8")
    return re.search(rf"(?ms)^{name}\(\) \{{\n.*?^\}}\n", source).group(0)

@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires Linux Bash")
class UnitCleanupTests(unittest.TestCase):
    def run_cleanup(self, kernel):
        with tempfile.TemporaryDirectory(prefix="next-unit-cleanup-") as tmp:
            root = Path(tmp)
            base = root / "task"
            base.mkdir(mode=0o700)
            for name in ("owner", "state", "worker", "run.log"):
                (base / name).write_text("fixture")
            (root / "entry.sh").write_text("fixture")
            (root / "unit.service").write_text("fixture\n")
            path = ROOT / ("next-vps-kernel-update.sh" if kernel else "next-vps-setup.sh")
            name = "cleanup" if kernel else "cleanup_success"
            body = r'''
set -Eeuo pipefail
BASE=$FIXTURE_ROOT/task
STATE=$BASE/state
STATE_FILE=$STATE
WORKER=$BASE/worker
LOG=$BASE/run.log
UNIT_FILE=$FIXTURE_ROOT/unit.service
PURGE_MANIFEST=$BASE/purge
RESULT=$FIXTURE_ROOT/result
UNIT=fixture.service
declare -A S=([result_status]=cleanup_pending [entry]="$FIXTURE_ROOT/entry.sh" [entry_path]="$FIXTURE_ROOT/entry.sh" [entry_id]=fixture [entry_identity]=fixture [script_sha]=fixture [entry_sha]=fixture [target_abi]=fixture [target_kernel]=fixture)
S[ssh_port]=56789; S[meta]=fixture; S[target_pkg]=fixture; S[target_version]=fixture
die(){ echo "$*" >&2; exit 93; }
verify_configuration(){ :; }; snapshot_result(){ :; }; verify_target(){ :; }; verify_owned(){ :; }; verify_task_files(){ :; }
select_old(){ :; }; inventory(){ :; }
save_to(){ printf '%s\n' "${S[result_status]}" > "$1"; }; write_state_to(){ save_to "$1"; }
apt_run(){ [[ $1 == clean ]]; }
publish_login_notice(){ :; }; official_apt_cleanup(){ :; }
plain_file(){ [[ -f $1 && ! -L $1 ]]; }; plain_root_file(){ plain_file "$1"; }
safe_entry(){ plain_file "$1"; }; safe_entry_path(){ plain_file "$1"; }
identity(){ echo fixture; }; file_identity(){ echo fixture; }
sha(){ echo fixture; }; file_sha(){ echo fixture; }
unit_content(){ echo fixture; }
note(){ :; }; nv_ui_heading(){ :; }
systemctl(){
 printf '%s\n' "$*" >> "$FIXTURE_ROOT/systemctl.calls"
 [[ $* == '--no-reload disable fixture.service' ]] || { echo 'unsafe active-unit reload' >&2; exit 94; }
}
'''
            body += extract(path, name) + "\n" + name
            # The initializer uses its named log file; provide that exact name.
            if not kernel:
                (base / "run.log").rename(base / "next-vps-setup.log")
            env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "FIXTURE_ROOT": str(root)}
            proc = subprocess.run(["bash", "-c", body], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertEqual((root / "result").read_text(), "complete\n")
            self.assertFalse(base.exists())
            self.assertFalse((root / "unit.service").exists())
            self.assertEqual((root / "systemctl.calls").read_text(), "--no-reload disable fixture.service\n")

    def test_initializer_cleanup_does_not_reload_its_active_deleted_definition(self):
        self.run_cleanup(False)

    def test_kernel_cleanup_does_not_reload_its_active_deleted_definition(self):
        self.run_cleanup(True)

if __name__ == "__main__":
    unittest.main()
