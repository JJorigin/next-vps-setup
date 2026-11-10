"""User-facing terminal messages, tested without system access or maintenance.

The UI library is sourced in an ordinary Bash subprocess with a temporary cwd
and a deny-only PATH. No production entry point or system command is run.
"""

from __future__ import annotations

import errno
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

if os.name == "posix":
    import pty


UI_LIBRARY = Path(__file__).resolve().parents[1] / "lib" / "user-interface.sh"
BASH = shutil.which("bash")


@unittest.skipUnless(os.name == "posix" and BASH, "requires Linux/WSL Bash")
class UserInterfaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="next-ui-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.blocked = self.root / "blocked-command.txt"
        for name in (
            "apt", "apt-get", "dpkg", "systemctl", "reboot", "shutdown",
            "rm", "touch", "curl", "wget", "cat", "tail", "date",
        ):
            stub = self.bin / name
            stub.write_text(
                f"#!{BASH}\n"
                'printf "%s\\n" "$0 $*" >> "$UI_BLOCKED_LOG"\nexit 97\n',
                encoding="utf-8", newline="\n",
            )
            stub.chmod(0o700)

    def tearDown(self) -> None:
        self.assertFalse(self.blocked.exists(), "UI attempted an external command")

    def run_ui(
        self, body: str, *args: str, tty: bool = False,
        term: str = "xterm-256color", no_color: str | None = None,
    ) -> str:
        env = {
            "PATH": str(self.bin), "LC_ALL": "C.UTF-8", "TERM": term,
            "UI_LIBRARY": str(UI_LIBRARY), "UI_BLOCKED_LOG": str(self.blocked),
        }
        if no_color is not None:
            env["NO_COLOR"] = no_color
        command = [
            BASH, "--noprofile", "--norc", "-c",
            'set -Eeuo pipefail\nsource "$UI_LIBRARY"\n' + body,
            "ui-test", *args,
        ]
        if not tty:
            proc = subprocess.run(
                command, env=env, cwd=self.root, text=True,
                capture_output=True, timeout=10,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertEqual(proc.stderr, "")
            return proc.stdout

        master, slave = pty.openpty()
        try:
            proc = subprocess.run(
                command, env=env, cwd=self.root, stdout=slave,
                stderr=subprocess.PIPE, timeout=10,
            )
        finally:
            os.close(slave)
        chunks: list[bytes] = []
        try:
            while True:
                try:
                    chunk = os.read(master, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                chunks.append(chunk)
        finally:
            os.close(master)
        output = b"".join(chunks).decode("utf-8").replace("\r\n", "\n")
        self.assertEqual(proc.returncode, 0, output + proc.stderr.decode("utf-8"))
        self.assertEqual(proc.stderr, b"")
        return output

    def test_source_only_defines_functions_without_output_or_files(self) -> None:
        before = set(self.root.iterdir())
        self.assertEqual(self.run_ui(":"), "")
        self.assertEqual(set(self.root.iterdir()), before)

    def test_key_stages_are_readable_and_unknown_stage_has_fallback(self) -> None:
        expectations = {
            "swap": "检查和准备交换空间",
            "update": "更新 Debian 官方软件包和内核",
            "configure": "配置主机名、时区和 SSH 防护",
            "install": "下载并安装官方内核",
            "reboot": "等待重启并继续任务",
            "verify": "重启后核验配置和服务",
            "purge": "核验通过，清理旧内核",
            "cleanup": "清理本次任务文件",
            "done": "任务已完成",
            "unknown-stage": "检查运行环境",
        }
        for stage, expected in expectations.items():
            with self.subTest(stage=stage):
                self.assertEqual(self.run_ui('nv_ui_stage_name "$1"', stage), expected)

    def test_launch_explains_reboot_manual_reconnect_and_time_is_not_success(self) -> None:
        output = self.run_ui(
            'nv_ui_launch "$1" "$2" "$3" "$4"',
            "内核维护", "3–10", "/var/lib/kernel-result.tsv", "/var/lib/task/run.log",
        )
        self.assertIn("内核维护 · 后台任务已提交", output)
        self.assertIn("自动重启", output)
        self.assertIn("SSH 连接会断开", output)
        self.assertIn("SSH 不会自动重连", output)
        self.assertIn("原账号和端口手动连接", output)
        self.assertIn("3–10 分钟", output)
        self.assertIn("请勿仅凭等待时间判断完成", output)

    def test_launch_explains_one_time_root_notice_and_result_fallback(self) -> None:
        output = self.run_ui(
            'nv_ui_launch "$1" "$2" "$3" "$4"',
            "系统初始化", "5–10", "/var/lib/setup-result.tsv", "/var/lib/setup/run.log",
        )
        self.assertIn("通过 SSH 直接登录 root（登录 Shell 为 Bash）", output)
        self.assertIn("显示一次后自动清理", output)
        self.assertIn("任务仍在执行时不会报成功", output)
        self.assertIn("如未看到登录提示", output)
        self.assertIn("cat /var/lib/setup-result.tsv", output)
        self.assertIn("tail -f /var/lib/setup/run.log", output)

    def test_non_tty_has_no_ansi_even_when_term_supports_color(self) -> None:
        output = self.run_ui('nv_ui_heading "标题"', term="xterm-256color")
        self.assertIn("标题", output)
        self.assertNotIn("\x1b", output)

    def test_tty_color_is_optional_and_no_color_is_respected(self) -> None:
        colored = self.run_ui('nv_ui_heading "标题"', tty=True)
        self.assertIn("\x1b[1;36m", colored)
        self.assertIn("\x1b[0m", colored)
        plain = self.run_ui('nv_ui_heading "标题"', tty=True, no_color="1")
        self.assertNotIn("\x1b", plain)
        dumb = self.run_ui('nv_ui_heading "标题"', tty=True, term="dumb")
        self.assertNotIn("\x1b", dumb)

    def test_receipt_and_log_paths_remain_literal_not_executable(self) -> None:
        receipt = '/tmp/receipt $(touch receipt-marker); printf PWNED %s'
        log = '/tmp/log `touch log-marker`; $(reboot) %s\\n'
        title = '标题 $(touch title-marker) %s\\n'
        output = self.run_ui('nv_ui_launch "$1" "$2" "$3" "$4"', title, "3–10", receipt, log)
        self.assertIn(title + " · 后台任务已提交", output)
        self.assertIn("cat " + receipt, output)
        self.assertIn("tail -f " + log, output)
        for marker in ("receipt-marker", "log-marker", "title-marker"):
            self.assertFalse((self.root / marker).exists())

    def test_progress_warns_against_duplicate_start_without_claiming_completion(self) -> None:
        output = self.run_ui('nv_ui_progress "purge"')
        self.assertIn("正在执行：核验通过，清理旧内核", output)
        self.assertIn("不要重复启动或替换脚本", output)
        self.assertNotIn("任务已完成", output)

    def test_stopped_message_preserves_literal_reason_and_recovery_guidance(self) -> None:
        reason = '配置冲突：$(touch stopped-marker) %s\\n'
        output = self.run_ui('nv_ui_stopped "$1"', reason)
        self.assertIn("操作已停止 · 本次任务尚未完成", output)
        self.assertIn("若已有任务记录", output)
        self.assertIn("保留原脚本和日志", output)
        self.assertIn("原因：" + reason, output)
        self.assertFalse((self.root / "stopped-marker").exists())


if __name__ == "__main__":
    unittest.main()
