"""Render and verify both standalone downloads without executing Shell code."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
ENTRIES = ("next-vps-setup.sh", "next-vps-kernel-update.sh")
HELPERS = (
    ("user-interface", "lib/user-interface.sh", "# BEGIN EMBEDDED user-interface", "# END EMBEDDED user-interface"),
    ("ssh-notice", "lib/ssh-notice.sh", "# BEGIN EMBEDDED ssh-notice", "# END EMBEDDED ssh-notice"),
    ("task-lock", "lib/task-lock.sh", "# BEGIN EMBEDDED task-lock", "# END EMBEDDED task-lock"),
    ("official-apt", "lib/official-apt.sh", "# BEGIN NEXT-VPS OFFICIAL APT VIEW", "# END NEXT-VPS OFFICIAL APT VIEW"),
    ("kernel-identity", "lib/kernel-identity.sh", "# BEGIN EMBEDDED kernel-identity", "# END EMBEDDED kernel-identity"),
)


class BuildError(ValueError):
    """An incomplete or ambiguous build input must never be published."""


def read_regular(path: Path, *, required: bool = True) -> bytes | None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        if not required:
            return None
        raise BuildError(f"required file is missing: {path}") from None
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise BuildError(f"expected a regular, non-symlink file: {path}")
    return path.read_bytes()


def read_source(path: Path) -> str:
    data = read_regular(path)
    assert data is not None
    if data.startswith(b"\xef\xbb\xbf") or b"\r" in data or b"\0" in data:
        raise BuildError(f"source must use UTF-8 without BOM, NUL or CR: {path}")
    return data.decode("utf-8")


def marker_span(text: str, begin: str, end: str) -> tuple[int, int]:
    starts = list(re.finditer(r"(?m)^" + re.escape(begin) + r"\n", text))
    stops = list(re.finditer(r"(?m)^" + re.escape(end) + r"\n", text))
    if len(starts) != 1 or len(stops) != 1 or starts[0].end() > stops[0].start():
        raise BuildError(f"expected exactly one ordered marker pair: {begin}")
    return starts[0].start(), stops[0].end()


def entry_spans(text: str) -> list[tuple[int, int]]:
    spans = [marker_span(text, begin, end) for _, _, begin, end in HELPERS]
    previous_end = 0
    for start, stop in spans:
        if start < previous_end:
            raise BuildError("embedded helper blocks overlap or are out of order")
        previous_end = stop
    return spans


def render_outputs(root: Path = ROOT) -> dict[str, bytes]:
    """Validate every input, then return the complete four-file build plan."""
    root = Path(root)
    blocks = []
    for name, source, begin, end in HELPERS:
        content = read_source(root / source).rstrip("\n") + "\n"
        if name == "official-apt":
            start, stop = marker_span(content, begin, end)
            if start != 0 or stop != len(content):
                raise BuildError("official APT library must be bounded by its markers")
            blocks.append(content)
        else:
            blocks.append(begin + "\n" + content + end + "\n")
    inputs = {name: read_source(root / name) for name in ENTRIES}
    # Missing checksums may be rebuilt; special files must not be adopted.
    for name in ENTRIES:
        read_regular((root / name).with_suffix(".sha256"), required=False)
    outputs = {}
    for name, text in inputs.items():
        spans = entry_spans(text)
        pieces = []
        previous_end = 0
        for (start, stop), block in zip(spans, blocks, strict=True):
            pieces.extend((text[previous_end:start], block))
            previous_end = stop
        pieces.append(text[previous_end:])
        rendered = "".join(pieces)
        entry_spans(rendered)  # Helper content must not introduce new markers.
        payload = rendered.encode("utf-8")
        outputs[name] = payload
        outputs[str(Path(name).with_suffix(".sha256"))] = (
            f"{hashlib.sha256(payload).hexdigest()}  {name}\n".encode("ascii")
        )
    return outputs


def build(root: Path = ROOT, *, check: bool = False) -> tuple[str, ...]:
    """Validate before writing; --check performs no filesystem mutation."""
    root = Path(root)
    outputs = render_outputs(root)
    changed = tuple(name for name, payload in outputs.items() if read_regular(root / name, required=False) != payload)
    if check or not changed:
        return changed
    staged = []
    try:
        # Stage the entire validated plan before replacing any destination.
        # Each replacement is atomic; four files are not one FS transaction.
        for name in changed:
            destination = root / name
            mode = stat.S_IMODE(destination.lstat().st_mode) if destination.exists() else 0o644
            descriptor, temporary_name = tempfile.mkstemp(prefix=".next-vps-build-", dir=root)
            temporary = Path(temporary_name)
            staged.append((temporary, destination))
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(outputs[name])
                stream.flush()
                os.fsync(stream.fileno())
            temporary.chmod(mode)
        for temporary, destination in staged:
            os.replace(temporary, destination)
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)
    return changed


def main(argv: list[str] | None = None, *, root: Path = ROOT) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check embedded helpers and SHA256 without writing files")
    args = parser.parse_args(argv)
    try:
        changed = build(root, check=args.check)
    except (BuildError, OSError, UnicodeError) as error:
        print(f"BUILD_ERROR: {error}", file=sys.stderr)
        return 2
    if args.check:
        if changed:
            print("NEEDS_REBUILD: " + ", ".join(changed))
            return 1
        print("CHECK_OK: embedded helpers and SHA256 files are current.")
    elif changed:
        print("BUILT: " + ", ".join(changed))
    else:
        print("BUILD_OK: already current.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
