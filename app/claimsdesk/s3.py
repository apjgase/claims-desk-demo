"""Path-style S3 client for Nutanix Objects.

Signs requests with AWS Signature Version 4. TLS verification is the caller's
choice; the stage 3 installer leaves it off for the lab.
"""
import hashlib
import hmac
from datetime import datetime, timezone
from typing import Dict, Optional
from urllib.parse import quote, urlparse

import httpx


class S3Error(Exception):
    def __init__(self, status: int, body: str):
        self.status = status
        self.body = body
        text = body.strip().splitlines()[0] if body.strip() else ""
        super().__init__("S3 responded {}: {}".format(status, text or "no body")[:300])


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _hmac(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def signing_key(secret: str, date_stamp: str, region: str) -> bytes:
    key = _hmac(("AWS4" + secret).encode("utf-8"), date_stamp)
    key = _hmac(key, region)
    key = _hmac(key, "s3")
    return _hmac(key, "aws4_request")


def canonical_uri(path: str) -> str:
    """Encode each path segment. Slashes stay, so path-style keys keep their structure."""
    return "/".join(quote(part, safe="-_.~") for part in path.split("/"))


def authorization(method: str, uri: str, headers: Dict[str, str], payload_hash: str,
                  access_key: str, secret: str, region: str, amz_date: str,
                  query: str = "") -> str:
    """Authorization header for one request. `headers` names are already lowercase."""
    names = sorted(headers)
    canonical_headers = "".join("{}:{}\n".format(name, headers[name].strip()) for name in names)
    signed = ";".join(names)
    canonical = "\n".join([
        method, canonical_uri(uri), query, canonical_headers, signed, payload_hash,
    ])
    scope = "{}/{}/s3/aws4_request".format(amz_date[:8], region)
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amz_date, scope, _sha256(canonical.encode("utf-8")),
    ])
    signature = hmac.new(
        signing_key(secret, amz_date[:8], region),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return (
        "AWS4-HMAC-SHA256 Credential={}/{}, SignedHeaders={}, Signature={}"
    ).format(access_key, scope, signed, signature)


class Client:
    def __init__(self, endpoint: str, bucket: str, access_key: str, secret_key: str,
                 region: str = "us-east-1", verify: bool = False,
                 transport: Optional[httpx.BaseTransport] = None, timeout: float = 30):
        parsed = urlparse(endpoint)
        if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.path not in ("", "/"):
            raise ValueError("S3 endpoint must be an http(s) origin, not a path: {}".format(endpoint))
        self.endpoint = endpoint.rstrip("/")
        self.host = parsed.netloc.lower()
        self.bucket = bucket
        self.access_key = access_key
        self.secret_key = secret_key
        self.region = region or "us-east-1"
        self._http = httpx.Client(verify=verify, timeout=timeout, transport=transport,
                                   follow_redirects=False)

    def close(self) -> None:
        self._http.close()

    def __enter__(self) -> "Client":
        return self

    def __exit__(self, *_args) -> None:
        self.close()

    def object_url(self, key: str) -> str:
        return "{}/{}/{}".format(self.endpoint, self.bucket, key)

    def _request(self, method: str, uri: str, body: bytes = b"", content_type: str = "") -> httpx.Response:
        payload_hash = _sha256(body)
        amz_date = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        headers = {
            "host": self.host,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": amz_date,
        }
        if content_type:
            headers["content-type"] = content_type
        signed = authorization(
            method, uri, headers, payload_hash, self.access_key, self.secret_key,
            self.region, amz_date,
        )
        headers["authorization"] = signed
        response = self._http.request(method, self.endpoint + uri, content=body or None, headers=headers)
        return response

    def _raise(self, response: httpx.Response) -> None:
        if response.status_code >= 400:
            raise S3Error(response.status_code, response.text)

    def head_bucket(self) -> None:
        response = self._request("HEAD", "/" + self.bucket)
        if response.status_code in (200, 204):
            return
        # Some gateways reject HEAD and answer GET ?max-keys=0. Try that once.
        if response.status_code in (400, 403, 405, 501):
            listed = self._request("GET", "/" + self.bucket, b"")
            # GET with an empty query is ListBucket on a few stacks and a bucket
            # probe on others. A 200 is enough to know the key can see the bucket.
            if listed.status_code in (200, 204):
                return
            self._raise(listed)
        self._raise(response)

    def head_object(self, key: str) -> bool:
        response = self._request("HEAD", "/{}/{}".format(self.bucket, key))
        if response.status_code in (200, 204):
            return True
        if response.status_code == 404:
            return False
        self._raise(response)
        return False

    def get_object(self, key: str) -> Optional[bytes]:
        """Object body, or None when the key does not exist."""
        response = self._request("GET", "/{}/{}".format(self.bucket, key))
        if response.status_code == 404:
            return None
        self._raise(response)
        return response.content

    def put_object(self, key: str, body: bytes, content_type: str) -> str:
        uri = "/{}/{}".format(self.bucket, key)
        response = self._request("PUT", uri, body, content_type)
        self._raise(response)
        return self.object_url(key)


def client_from(cfg, transport: Optional[httpx.BaseTransport] = None) -> Client:
    return Client(
        endpoint=cfg["s3_endpoint"],
        bucket=cfg["s3_bucket"],
        access_key=cfg["s3_access_key"],
        secret_key=cfg["s3_secret_key"],
        region=cfg.get("s3_region") or "us-east-1",
        verify=bool(cfg.get("s3_verify_tls")),
        transport=transport,
    )
