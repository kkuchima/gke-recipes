"""Pure-stdlib 1024x1024 RGB PNG generator (no Pillow/NumPy required on host)."""
import struct
import sys
import zlib


def write_png(path: str, width: int = 1024, height: int = 1024) -> None:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    rows = []
    for y in range(height):
        # Filter byte 0 + deterministic interference pattern
        row = bytearray([0])
        for x in range(width):
            r = (x * 5 + y * 3) & 0xFF
            g = ((x ^ y) + 64) & 0xFF
            b = (x * 2 + y * 7) & 0xFF
            row.extend((r, g, b))
        rows.append(bytes(row))

    raw = b"".join(rows)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, level=6))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/sample_sensor_001.png"
    write_png(out)
    print(f"Generated 1024x1024 RGB sensor PNG: {out}")
