import struct
import zlib
from pathlib import Path

# Create a 1024x1024 opaque RGB PNG for App Store icon packaging.
width, height = 1024, 1024
# Raw image data: for each scanline, 1 filter byte (0) + 1024 * 3 bytes (R, G, B)
# Dark slate background with a warm amber card / lens motif
raw = bytearray()
for y in range(height):
    raw.append(0)  # filter type 0 (None)
    for x in range(width):
        # Slate background
        r, g, b = 18, 22, 28
        # Central card outline
        if 220 <= x <= 804 and 220 <= y <= 804:
            # Card face
            r, g, b = 28, 36, 48
            # Inner aperture / framing rect
            if 340 <= x <= 684 and 340 <= y <= 684:
                r, g, b = 224, 142, 38  # Amber
                if 360 <= x <= 664 and 360 <= y <= 664:
                    r, g, b = 16, 20, 26  # Dark lens opening
                    # Center dot
                    dx = x - 512
                    dy = y - 512
                    if dx * dx + dy * dy <= 48 * 48:
                        r, g, b = 240, 244, 250
        raw.extend((r, g, b))

compressed = zlib.compress(bytes(raw), level=6)

def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xffffffff
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

png = bytearray(b"\x89PNG\r\n\x1a\n")
# IHDR chunk: 1024x1024, 8 bits/channel, color type 2 (RGB), defl=0, filt=0, interl=0
png.extend(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
# IDAT chunk
png.extend(chunk(b"IDAT", compressed))
# IEND chunk
png.extend(chunk(b"IEND", b""))

target = Path.home() / "media/shotdeck/images/AppIcon-1024.png"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(bytes(png))
(Path(__file__).resolve().parents[1] / "ShotDeck/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png").write_bytes(bytes(png))
source = Path.home() / "media/shotdeck/sources/generate_app_icon.py"
source.parent.mkdir(parents=True, exist_ok=True)
source.write_bytes(Path(__file__).read_bytes())
print(f"Wrote {len(png)} bytes to {target}")
