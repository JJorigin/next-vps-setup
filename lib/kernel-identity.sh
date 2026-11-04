# Confirm the running amd64 build, including upgrades that reuse an ABI name.
# File trust/ownership is checked by the caller before this read-only helper.
nv_kernel_image_matches() {
    /usr/bin/python3 -I - "$1" "$2" "$3" <<'NEXT_VPS_KERNEL_IDENTITY'
import os
import stat
import struct
import sys

def check(path, release, version):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o022:
            raise ValueError("unsafe kernel image type or permissions")
        with os.fdopen(fd, "rb", closefd=False) as image:
            header = image.read(0x210)
            if (len(header) != 0x210 or header[0x1fe:0x200] != b"\x55\xaa"
                    or header[0x202:0x206] != b"HdrS"
                    or struct.unpack_from("<H", header, 0x206)[0] < 0x200):
                raise ValueError("unsupported x86 boot header")
            setup_end = ((header[0x1f1] or 4) + 1) * 512
            offset = 0x200 + struct.unpack_from("<H", header, 0x20e)[0]
            if not 0x210 <= offset < min(setup_end, metadata.st_size):
                raise ValueError("invalid kernel version pointer")
            image.seek(offset)
            raw = image.read(min(512, setup_end - offset, metadata.st_size - offset))
            if b"\0" not in raw:
                raise ValueError("unterminated kernel version")
            banner = raw.split(b"\0", 1)[0]
            if not banner or any(byte < 32 or byte > 126 for byte in banner):
                raise ValueError("invalid kernel version text")
            banner = banner.decode("ascii")
            if not (banner.startswith(release + " (") and banner.endswith(") " + version)):
                raise ValueError("running kernel build differs from the target boot image")
    finally:
        os.close(fd)

try:
    check(*sys.argv[1:])
except (OSError, ValueError, struct.error) as error:
    print("KERNEL_IDENTITY_ERROR: " + str(error), file=sys.stderr)
    raise SystemExit(1)
NEXT_VPS_KERNEL_IDENTITY
}
