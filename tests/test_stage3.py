"""Stage 3: S3 signature and the document service, with no PostgreSQL."""
import base64
import json
import sys
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "app"))

from claimsdesk import docs, s3  # noqa: E402


# AWS documentation example: GET Object, us-east-1, 2013-05-24T00:00:00Z.
# https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
def test_sigv4_matches_aws_get_object_example():
    headers = {
        "host": "examplebucket.s3.amazonaws.com",
        "range": "bytes=0-9",
        "x-amz-content-sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "x-amz-date": "20130524T000000Z",
    }
    header = s3.authorization(
        "GET", "/test.txt", headers, headers["x-amz-content-sha256"],
        "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "us-east-1", "20130524T000000Z",
    )
    assert header.endswith(
        "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    )


PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)


@pytest.fixture
def docs_client(tmp_path, monkeypatch):
    mount = tmp_path / "share"
    mount.mkdir()
    cfg = {
        "nfs_export": "10.10.140.11:/claims-docs",
        "nfs_mount": str(mount),
        "s3_endpoint": "https://objects.example",
        "s3_bucket": "claims",
        "s3_access_key": "AKIATEST",
        "s3_secret_key": "secret",
        "s3_region": "us-east-1",
        "s3_verify_tls": False,
    }
    path = tmp_path / "docs.json"
    path.write_text(json.dumps(cfg))
    monkeypatch.setenv("CLAIMS_CONFIG", str(path))
    puts = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "HEAD" and request.url.path == "/claims":
            return httpx.Response(200)
        if request.method == "HEAD" and request.url.path.endswith("/packet.json"):
            return httpx.Response(200 if puts else 404)
        if request.method == "PUT" and request.url.path.endswith("/packet.json"):
            puts.append(request.content)
            return httpx.Response(200)
        return httpx.Response(500, text="{} {}".format(request.method, request.url.path))

    transport = httpx.MockTransport(handler)

    def build(loaded, transport=None, _transport=transport):
        return s3.Client(
            endpoint=loaded["s3_endpoint"], bucket=loaded["s3_bucket"],
            access_key=loaded["s3_access_key"], secret_key=loaded["s3_secret_key"],
            region=loaded["s3_region"], verify=False, transport=transport or _transport,
        )

    monkeypatch.setattr(s3, "client_from", build)
    with TestClient(docs.app) as client:
        client.puts = puts
        client.mount = mount
        yield client


def test_photo_round_trip_and_rejection(docs_client):
    assert docs_client.post("/v1/photos", data={"claim_number": "../etc"},
                            files={"photo": ("a.png", PNG, "image/png")}).status_code == 400
    assert docs_client.post("/v1/photos", data={"claim_number": "CLM-000010"},
                            files={"photo": ("a.txt", b"hello", "text/plain")}).status_code == 415
    stored = docs_client.post("/v1/photos", data={"claim_number": "CLM-000010"},
                              files={"photo": ("a.png", PNG, "image/png")})
    assert stored.status_code == 200, stored.text
    assert stored.json()["photo_path"].endswith("/CLM-000010/photo.png")
    fetched = docs_client.get("/v1/photos/CLM-000010")
    assert fetched.status_code == 200 and fetched.content == PNG
    assert (docs_client.mount / "CLM-000010" / "photo.png").is_file()


def test_packet_is_written_once(docs_client):
    body = {"claim_number": "CLM-000010", "status": "APPROVED", "amount": "10.00"}
    first = docs_client.post("/v1/packets", json=body)
    assert first.status_code == 200, first.text
    assert first.json()["packet_url"] == "https://objects.example/claims/CLM-000010/packet.json"
    assert first.json()["already_stored"] is False
    assert len(docs_client.puts) == 1
    second = docs_client.post("/v1/packets", json=body)
    assert second.json()["already_stored"] is True
    assert len(docs_client.puts) == 1
