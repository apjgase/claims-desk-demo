"""Facts about claim photos on the share: content hash, perceptual hash, EXIF capture date.

Used by the document service for the fraud checks, and by the chat service to shrink
a photo before it goes to the vision model.
"""
import hashlib
import io
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

from PIL import Image, UnidentifiedImageError

EXIF_IFD = 0x8769
DATETIME_ORIGINAL = 36867
DATETIME = 306


def dhash(img: Image.Image) -> str:
    """64-bit difference hash. Re-encoded or resized copies of one picture stay close."""
    small = img.convert("L").resize((9, 8), Image.Resampling.LANCZOS)
    px = small.tobytes()
    bits = 0
    for row in range(8):
        for col in range(8):
            bits = (bits << 1) | (1 if px[row * 9 + col] > px[row * 9 + col + 1] else 0)
    return "{:016x}".format(bits)


def hamming(a: str, b: str) -> int:
    return bin(int(a, 16) ^ int(b, 16)).count("1")


def taken_at(img: Image.Image) -> Optional[str]:
    """EXIF capture time as ISO 8601, or None. Camera clocks have no time zone."""
    exif = img.getexif()
    raw = exif.get_ifd(EXIF_IFD).get(DATETIME_ORIGINAL) or exif.get(DATETIME)
    if not raw:
        return None
    try:
        return datetime.strptime(str(raw).strip("\x00 "), "%Y:%m:%d %H:%M:%S").isoformat()
    except ValueError:
        return None


def facts(blob: bytes) -> Dict[str, Any]:
    out: Dict[str, Any] = {"sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob),
                           "dhash": None, "taken_at": None, "width": None, "height": None}
    try:
        with Image.open(io.BytesIO(blob)) as img:
            out["width"], out["height"] = img.size
            out["taken_at"] = taken_at(img)
            img.seek(0)
            out["dhash"] = dhash(img)
    except (UnidentifiedImageError, OSError, ValueError):
        pass
    return out


_cache: Dict[str, Tuple[int, int, Dict[str, Any]]] = {}


def file_facts(path: Path) -> Dict[str, Any]:
    """facts() for a file, cached until its size or mtime changes."""
    st = path.stat()
    key = str(path)
    hit = _cache.get(key)
    if hit and hit[0] == st.st_mtime_ns and hit[1] == st.st_size:
        return hit[2]
    found = facts(path.read_bytes())
    _cache[key] = (st.st_mtime_ns, st.st_size, found)
    return found


def shrink(blob: bytes, longest: int = 768) -> Tuple[bytes, str]:
    """JPEG copy with the longest side at most `longest` pixels, for a vision model."""
    with Image.open(io.BytesIO(blob)) as img:
        img = img.convert("RGB")
        img.thumbnail((longest, longest))
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=85)
    return buf.getvalue(), "image/jpeg"
