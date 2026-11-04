"""Embed shared, dependency-free helpers into the two standalone downloads."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parents[1]


def embed(text: str, name: str, content: str) -> str:
    begin = f"# BEGIN EMBEDDED {name}\n"
    end = f"# END EMBEDDED {name}\n"
    block = begin + content.rstrip("\n") + "\n" + end
    if begin in text:
        start = text.index(begin)
        stop = text.index(end, start) + len(end)
        return text[:start] + block + text[stop:]
    marker = "\ndie() {"
    if marker not in text:
        raise ValueError("missing helper insertion point")
    return text.replace(marker, "\n" + block + marker, 1)


for filename in ("next-vps-setup.sh", "next-vps-kernel-update.sh"):
    path = ROOT / filename
    text = path.read_text(encoding="utf-8")
    for helper in ("user-interface", "ssh-notice"):
        source = ROOT / "lib" / f"{helper}.sh"
        if source.exists():
            text = embed(text, helper, source.read_text(encoding="utf-8"))
    apt_source = ROOT / "lib" / "official-apt.sh"
    if apt_source.exists():
        begin = "# BEGIN NEXT-VPS OFFICIAL APT VIEW\n"
        end = "# END NEXT-VPS OFFICIAL APT VIEW\n"
        start = text.index(begin)
        stop = text.index(end, start) + len(end)
        text = text[:start] + apt_source.read_text(encoding="utf-8").rstrip("\n") + "\n" + text[stop:]
    path.write_text(text, encoding="utf-8", newline="\n")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    path.with_suffix(".sha256").write_text(
        f"{digest}  {filename}\n", encoding="utf-8", newline="\n"
    )
