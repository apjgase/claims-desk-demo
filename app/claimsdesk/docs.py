"""Document VM service: photo to Nutanix Files, accepted packet to Objects.

Run: uvicorn claimsdesk.docs:app --host 0.0.0.0 --port 8090

The portal calls this over HTTP. The browser does not.
"""
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import httpx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse

from . import __version__, config, s3

# 10 MB photos. The packet is the claim as JSON, far smaller.
MAX_PHOTO = 10 * 1024 * 1024
_CLAIM = re.compile(r"^CLM-[0-9]{1,12}$")

app = FastAPI(title="Claims Desk documents", version=__version__,
              docs_url="/docs", openapi_url="/openapi.json", redoc_url=None)


def _cfg():
    return config.load()


def _claim_or_400(claim_number: str) -> str:
    if not _CLAIM.match(claim_number or ""):
        raise HTTPException(status_code=400, detail="claim_number must look like CLM-000001")
    return claim_number


def _photo_dir(mount: str, claim_number: str) -> Path:
    root = Path(mount).resolve()
    directory = (root / claim_number).resolve()
    if directory != root and root not in directory.parents:
        raise HTTPException(status_code=400, detail="photo path escapes the share")
    return directory


def _sniff(blob: bytes):
    if blob.startswith(b"\xff\xd8\xff"):
        return ".jpg", "image/jpeg"
    if blob.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png", "image/png"
    if blob.startswith((b"GIF87a", b"GIF89a")):
        return ".gif", "image/gif"
    if len(blob) >= 12 and blob.startswith(b"RIFF") and blob[8:12] == b"WEBP":
        return ".webp", "image/webp"
    return None


def _find_photo(directory: Path):
    if not directory.is_dir():
        return None
    found = sorted(p for p in directory.glob("photo.*") if p.is_file() and not p.name.startswith("."))
    return found[0] if found else None


@app.get("/health")
def health():
    cfg = _cfg()
    mount = cfg["nfs_mount"]
    mounted = os.path.ismount(mount)
    return {
        "status": "ok" if mounted else "nfs not mounted",
        "service": "claims-docs",
        "version": __version__,
        "host": config.host_identity(),
        "runtime": config.runtime(),
        "nfs": {"export": cfg["nfs_export"], "mount": mount, "mounted": mounted},
        "s3": {
            "endpoint": cfg["s3_endpoint"],
            "bucket": cfg["s3_bucket"],
            "tls_verify": bool(cfg["s3_verify_tls"]),
        },
    }


@app.post("/v1/photos")
async def put_photo(claim_number: str = Form(""), photo: UploadFile = File(...)):
    claim_number = _claim_or_400(claim_number)
    blob = await photo.read()
    if not blob:
        raise HTTPException(status_code=400, detail="photo is empty")
    if len(blob) > MAX_PHOTO:
        raise HTTPException(status_code=413, detail="photo larger than 10 MB")
    sniffed = _sniff(blob)
    if sniffed is None:
        raise HTTPException(status_code=415, detail="photo must be JPEG, PNG, GIF, or WebP")
    ext, _media = sniffed
    cfg = _cfg()
    directory = _photo_dir(cfg["nfs_mount"], claim_number)
    directory.mkdir(parents=True, exist_ok=True)
    for old in directory.glob("photo.*"):
        if old.is_file():
            old.unlink()
    target = directory / ("photo" + ext)
    partial = directory / ".photo.partial"
    partial.write_bytes(blob)
    os.chmod(partial, 0o644)
    os.replace(partial, target)
    return {"claim_number": claim_number, "photo_path": str(target), "bytes": len(blob)}


@app.get("/v1/photos/{claim_number}")
def get_photo(claim_number: str):
    claim_number = _claim_or_400(claim_number)
    path = _find_photo(_photo_dir(_cfg()["nfs_mount"], claim_number))
    if path is None:
        raise HTTPException(status_code=404, detail="photo not found")
    media = {
        ".jpg": "image/jpeg", ".png": "image/png", ".gif": "image/gif", ".webp": "image/webp",
    }.get(path.suffix.lower(), "application/octet-stream")
    return FileResponse(path, media_type=media)


@app.post("/v1/packets")
async def put_packet(payload: dict):
    claim_number = _claim_or_400(str(payload.get("claim_number") or ""))
    cfg = _cfg()
    key = "{}/packet.json".format(claim_number)
    document = {
        "claim_number": claim_number,
        "claim": payload,
        "accepted_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "written_by_host": config.host_identity()["hostname"],
    }
    body = json.dumps(document, indent=2).encode("utf-8")
    already = False
    try:
        with s3.client_from(cfg) as client:
            if client.head_object(key):
                url = client.object_url(key)
                already = True
            else:
                url = client.put_object(key, body, "application/json")
    except s3.S3Error as exc:
        # A WORM bucket rejects a second PUT. If the object is already there, use it.
        if exc.status in (403, 409, 412):
            try:
                with s3.client_from(cfg) as client:
                    if client.head_object(key):
                        return {"claim_number": claim_number, "packet_url": client.object_url(key),
                                "already_stored": True}
            except s3.S3Error:
                pass
        return JSONResponse(status_code=502, content={"detail": str(exc)})
    return {"claim_number": claim_number, "packet_url": url, "already_stored": already}


def install_check() -> None:
    """Used by update.sh on the document VM: the share is mounted and the bucket answers."""
    cfg = _cfg()
    mount = cfg["nfs_mount"]
    if not os.path.ismount(mount):
        sys.exit("ERROR: {} is not a mounted filesystem".format(mount))
    missing = [name for name in ("s3_endpoint", "s3_bucket", "s3_access_key", "s3_secret_key")
               if not cfg.get(name)]
    if missing:
        sys.exit("ERROR: document settings missing: {}".format(", ".join(missing)))
    try:
        with s3.client_from(cfg) as client:
            client.head_bucket()
    except (s3.S3Error, httpx.HTTPError, ValueError) as exc:
        sys.exit("ERROR: cannot reach bucket {} at {} ({})".format(
            cfg["s3_bucket"], cfg["s3_endpoint"], exc))
    print("ok: bucket {} at {} (TLS verification {})".format(
        cfg["s3_bucket"], cfg["s3_endpoint"], "on" if cfg["s3_verify_tls"] else "off"))


def main(argv=None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    if args == ["check"]:
        install_check()
        return
    sys.exit("usage: python -m claimsdesk.docs check")


if __name__ == "__main__":
    main()
