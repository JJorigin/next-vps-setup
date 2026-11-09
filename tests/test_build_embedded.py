"""Builder regressions use only temporary project copies; no Shell is run."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest


BUILDER = Path(__file__).resolve().parents[1] / "tools/build_embedded.py"
ENTRIES = ("next-vps-setup.sh", "next-vps-kernel-update.sh")
MARKERS = (
    ("# BEGIN EMBEDDED user-interface", "# END EMBEDDED user-interface"),
    ("# BEGIN EMBEDDED ssh-notice", "# END EMBEDDED ssh-notice"),
    ("# BEGIN EMBEDDED task-lock", "# END EMBEDDED task-lock"),
    ("# BEGIN NEXT-VPS OFFICIAL APT VIEW", "# END NEXT-VPS OFFICIAL APT VIEW"),
    ("# BEGIN EMBEDDED kernel-identity", "# END EMBEDDED kernel-identity"),
)


class EmbeddedBuilderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="next-builder-test-", dir=os.environ.get("NEXT_VPS_TEST_TMP"))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "tools").mkdir()
        (self.root / "lib").mkdir()
        self.tool = self.root / "tools/build_embedded.py"
        self.tool.write_bytes(BUILDER.read_bytes())
        self.entry = "#!/bin/bash\n" + "".join(
            f"{begin}\n# stale embedded content\n{end}\n" for begin, end in MARKERS
        ) + "# untouched tail\n"
        for name in ENTRIES:
            (self.root / name).write_text(self.entry, encoding="utf-8", newline="\n")
            (self.root / name).with_suffix(".sha256").write_text("stale checksum\n", encoding="ascii", newline="\n")
        (self.root / "lib/user-interface.sh").write_text("# fresh UI\n", encoding="ascii", newline="\n")
        (self.root / "lib/ssh-notice.sh").write_text("# fresh notice\n", encoding="ascii", newline="\n")
        (self.root / "lib/task-lock.sh").write_text("# fresh task lock\n", encoding="ascii", newline="\n")
        (self.root / "lib/kernel-identity.sh").write_text("# fresh kernel identity\n", encoding="ascii", newline="\n")
        (self.root / "lib/official-apt.sh").write_text(
            MARKERS[3][0] + "\n# fresh APT\n" + MARKERS[3][1] + "\n", encoding="ascii", newline="\n"
        )

    def load_builder(self):
        # An old module that builds on import can touch only this fixture.
        spec = importlib.util.spec_from_file_location("next_builder_fixture", self.tool)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        old = sys.dont_write_bytecode
        sys.dont_write_bytecode = True
        try:
            spec.loader.exec_module(module)
        finally:
            sys.dont_write_bytecode = old
        return module

    def snapshot(self) -> dict[str, tuple[bytes, int]]:
        return {
            str(p.relative_to(self.root)): (p.read_bytes(), p.stat().st_mtime_ns)
            for p in self.root.rglob("*") if p.is_file() and not p.is_symlink()
        }

    def test_import_has_no_write_side_effects(self) -> None:
        before = self.snapshot()
        self.load_builder()
        self.assertEqual(self.snapshot(), before)

    def test_render_is_read_only_and_hashes_exact_output_bytes(self) -> None:
        builder = self.load_builder()
        before = self.snapshot()
        outputs = builder.render_outputs(self.root)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(len(outputs), 4)
        for name in ENTRIES:
            payload = outputs[name]
            self.assertIn(b"# fresh UI\n", payload)
            self.assertIn(b"# fresh notice\n", payload)
            self.assertIn(b"# fresh task lock\n", payload)
            self.assertIn(b"# fresh APT\n", payload)
            self.assertNotIn(b"stale embedded", payload)
            self.assertTrue(payload.endswith(b"# untouched tail\n"))
            digest = hashlib.sha256(payload).hexdigest()
            self.assertEqual(outputs[str(Path(name).with_suffix(".sha256"))], f"{digest}  {name}\n".encode())

    def test_build_is_idempotent_and_preserves_file_mode(self) -> None:
        builder = self.load_builder()
        for name in ENTRIES:
            (self.root / name).chmod(0o700)
        modes = {name: (self.root / name).stat().st_mode for name in ENTRIES}
        self.assertEqual(len(builder.build(self.root)), 4)
        self.assertEqual(builder.build(self.root, check=True), ())
        before = self.snapshot()
        self.assertEqual(builder.build(self.root), ())
        self.assertEqual(self.snapshot(), before)
        for name in ENTRIES:
            self.assertEqual((self.root / name).stat().st_mode, modes[name])
        self.assertFalse(list(self.root.glob(".next-vps-build-*")))

    def test_check_detects_stale_outputs_without_writing(self) -> None:
        builder = self.load_builder()
        before = self.snapshot()
        self.assertEqual(len(builder.build(self.root, check=True)), 4)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(builder.main(["--check"], root=self.root), 1)
        self.assertEqual(self.snapshot(), before)
        builder.build(self.root)
        before = self.snapshot()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(builder.main(["--check"], root=self.root), 0)
        self.assertEqual(self.snapshot(), before)

    def test_missing_helper_cannot_partially_write_outputs(self) -> None:
        builder = self.load_builder()
        for name in ("user-interface", "ssh-notice", "task-lock", "official-apt", "kernel-identity"):
            with self.subTest(name=name):
                path = self.root / "lib" / f"{name}.sh"
                content = path.read_bytes()
                path.unlink()
                before = self.snapshot()
                with self.assertRaises(builder.BuildError):
                    builder.build(self.root)
                self.assertEqual(self.snapshot(), before)
                path.write_bytes(content)

    def test_missing_second_entry_cannot_partially_write_first(self) -> None:
        builder = self.load_builder()
        (self.root / ENTRIES[1]).unlink()
        before = self.snapshot()
        with self.assertRaises(builder.BuildError):
            builder.build(self.root)
        self.assertEqual(self.snapshot(), before)

    def test_duplicate_or_inverted_markers_cannot_partially_write_outputs(self) -> None:
        builder = self.load_builder()
        path = self.root / ENTRIES[1]
        for begin, end in MARKERS:
            for malformed in (
                self.entry.replace(begin + "\n", "", 1),
                self.entry.replace(end + "\n", "", 1),
                self.entry + begin + "\n",
                self.entry + end + "\n",
                self.entry.replace(begin, "# placeholder", 1).replace(end, begin, 1).replace("# placeholder", end, 1),
            ):
                with self.subTest(begin=begin, malformed=malformed):
                    path.write_text(malformed, encoding="utf-8", newline="\n")
                    before = self.snapshot()
                    with self.assertRaises(builder.BuildError):
                        builder.build(self.root)
                    self.assertEqual(self.snapshot(), before)
        path.write_text(self.entry, encoding="utf-8", newline="\n")

    def test_interleaved_helper_blocks_are_rejected(self) -> None:
        builder = self.load_builder()
        text = "#!/bin/bash\n" + "\n".join((MARKERS[0][0], MARKERS[1][0], MARKERS[0][1], MARKERS[1][1], *(marker for pair in MARKERS[2:] for marker in pair))) + "\n"
        (self.root / ENTRIES[1]).write_text(text, encoding="utf-8", newline="\n")
        before = self.snapshot()
        with self.assertRaises(builder.BuildError):
            builder.build(self.root)
        self.assertEqual(self.snapshot(), before)

    def test_helper_cannot_inject_additional_markers(self) -> None:
        builder = self.load_builder()
        (self.root / "lib/user-interface.sh").write_text(MARKERS[1][0] + "\n", encoding="ascii", newline="\n")
        before = self.snapshot()
        with self.assertRaises(builder.BuildError):
            builder.build(self.root)
        self.assertEqual(self.snapshot(), before)

    def test_missing_checksum_can_be_rebuilt(self) -> None:
        builder = self.load_builder()
        (self.root / ENTRIES[0]).with_suffix(".sha256").unlink()
        builder.build(self.root)
        self.assertEqual(builder.build(self.root, check=True), ())

    def test_symlink_inputs_and_output_checksums_are_rejected(self) -> None:
        builder = self.load_builder()
        outside = self.root / "outside.txt"
        outside.write_text("external sentinel\n", encoding="ascii")
        for relative in ("lib/user-interface.sh", ENTRIES[0], "next-vps-kernel-update.sha256"):
            with self.subTest(relative=relative):
                path = self.root / relative
                content = path.read_bytes()
                path.unlink()
                try:
                    path.symlink_to(outside)
                except OSError as error:
                    path.write_bytes(content)
                    self.skipTest(f"this host cannot create symlinks: {error}")
                before = self.snapshot()
                with self.assertRaises(builder.BuildError):
                    builder.build(self.root)
                self.assertEqual(self.snapshot(), before)
                self.assertEqual(outside.read_text(), "external sentinel\n")
                path.unlink()
                path.write_bytes(content)

    def test_directory_input_is_rejected(self) -> None:
        builder = self.load_builder()
        path = self.root / "lib/ssh-notice.sh"
        path.unlink()
        path.mkdir()
        before = self.snapshot()
        with self.assertRaises(builder.BuildError):
            builder.build(self.root)
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
