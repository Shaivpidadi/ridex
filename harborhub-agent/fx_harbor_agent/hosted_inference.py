from __future__ import annotations

import asyncio
import base64
import http.client
import ipaddress
import json
import ssl
from collections.abc import Iterable
from urllib.parse import SplitResult, urlsplit


_MAX_REQUEST_HEAD_BYTES = 64 * 1024
_STREAM_CHUNK_BYTES = 64 * 1024
_DIAGNOSTIC_TARGET_HOST = "ai-gateway.vercel.sh"
_HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class HostedInferenceProxy:
    """Stream FX's loopback-only gateway requests to Harbor's credential proxy."""

    def __init__(self, upstream_url: str, token: str) -> None:
        if not token:
            raise ValueError("HOSTED_INFERENCE_TOKEN is empty")
        self._upstream = _validated_upstream(upstream_url)
        self._token = token
        self._server: asyncio.Server | None = None

    @property
    def local_url(self) -> str:
        if self._server is None or not self._server.sockets:
            raise RuntimeError("hosted inference proxy has not started")
        port = self._server.sockets[0].getsockname()[1]
        return f"http://127.0.0.1:{port}/v3/ai/language-model"

    async def start(self) -> None:
        if self._server is not None:
            raise RuntimeError("hosted inference proxy is already running")
        self._server = await asyncio.start_server(
            self._handle_client,
            host="127.0.0.1",
            port=0,
            limit=_MAX_REQUEST_HEAD_BYTES,
        )

    async def close(self) -> None:
        if self._server is None:
            return
        self._server.close()
        await self._server.wait_closed()
        self._server = None

    async def __aenter__(self) -> HostedInferenceProxy:
        await self.start()
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()

    async def _handle_client(
        self,
        client_reader: asyncio.StreamReader,
        client_writer: asyncio.StreamWriter,
    ) -> None:
        upstream_writer: asyncio.StreamWriter | None = None
        response_started = False
        try:
            raw_head = await client_reader.readuntil(b"\r\n\r\n")
            if len(raw_head) > _MAX_REQUEST_HEAD_BYTES:
                raise ValueError("FX gateway request headers are too large")
            method, request_target, headers = _parse_request_head(raw_head)
            content_length = _content_length(headers)
            upstream_reader, upstream_writer = await asyncio.wait_for(
                self._open_upstream(),
                timeout=30,
            )
            upstream_writer.write(
                _upstream_request_head(
                    method=method,
                    request_target=request_target,
                    upstream=self._upstream,
                    token=self._token,
                    headers=headers,
                    content_length=content_length,
                )
            )
            await _relay_exactly(
                client_reader,
                upstream_writer,
                content_length,
            )
            await upstream_writer.drain()

            while chunk := await upstream_reader.read(_STREAM_CHUNK_BYTES):
                response_started = True
                client_writer.write(chunk)
                await client_writer.drain()
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, OSError, ValueError):
            if not response_started:
                await _write_bad_gateway(client_writer)
        finally:
            if upstream_writer is not None:
                upstream_writer.close()
                await _wait_closed(upstream_writer)
            client_writer.close()
            await _wait_closed(client_writer)

    async def _open_upstream(
        self,
    ) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        host = self._upstream.hostname
        if host is None:
            raise ValueError("HOSTED_INFERENCE_URL has no hostname")
        if self._upstream.scheme == "https":
            context = ssl.create_default_context()
            return await asyncio.open_connection(
                host,
                self._upstream.port or 443,
                ssl=context,
                server_hostname=host,
            )
        return await asyncio.open_connection(host, self._upstream.port or 80)


async def probe_hosted_inference(upstream_url: str, token: str) -> dict[str, object]:
    """Inspect Harbor's public gateway contract without issuing inference."""

    if not token:
        raise ValueError("HOSTED_INFERENCE_TOKEN is empty")
    upstream = _validated_upstream(upstream_url)
    return await asyncio.to_thread(_probe_hosted_inference_sync, upstream, token)


def _probe_hosted_inference_sync(
    upstream: SplitResult,
    token: str,
) -> dict[str, object]:
    base_path = upstream.path or "/"
    probes = [
        ("GET", base_path),
        ("OPTIONS", base_path),
        ("GET", f"{base_path.rstrip('/')}/"),
        ("GET", "/openapi.json"),
        ("GET", f"{base_path.rstrip('/')}/openapi.json"),
    ]
    results: list[dict[str, object]] = []
    for method, path in probes:
        results.append(_probe_request(upstream, token, method, path))
    results.extend(
        [
            _probe_request(
                upstream,
                token,
                "GET",
                base_path,
                auth_header="Proxy-Authorization",
                probe_type="proxy_authorization_origin_form",
            ),
            _probe_request(
                upstream,
                token,
                "HEAD",
                f"https://{_DIAGNOSTIC_TARGET_HOST}/v3/ai/language-model",
                auth_header="Proxy-Authorization",
                probe_type="proxy_authorization_absolute_form",
            ),
            _probe_request(
                upstream,
                token,
                "CONNECT",
                f"{_DIAGNOSTIC_TARGET_HOST}:443",
                auth_header="Authorization",
                probe_type="authorization_connect",
            ),
            _probe_request(
                upstream,
                token,
                "CONNECT",
                f"{_DIAGNOSTIC_TARGET_HOST}:443",
                auth_header="Proxy-Authorization",
                probe_type="proxy_authorization_connect",
            ),
        ]
    )
    return {
        "host": upstream.hostname,
        "base_path": base_path,
        "token_metadata": _token_metadata(token),
        "probes": results,
    }


def _probe_request(
    upstream: SplitResult,
    token: str,
    method: str,
    path: str,
    *,
    auth_header: str = "Authorization",
    probe_type: str = "origin_form",
) -> dict[str, object]:
    host = upstream.hostname
    if host is None:
        raise ValueError("HOSTED_INFERENCE_URL has no hostname")
    port = upstream.port or (443 if upstream.scheme == "https" else 80)
    connection_class = (
        http.client.HTTPSConnection
        if upstream.scheme == "https"
        else http.client.HTTPConnection
    )
    connection = connection_class(host, port, timeout=10)
    result: dict[str, object] = {
        "probe_type": probe_type,
        "method": method,
        "path": path,
        "auth_header": auth_header,
    }
    try:
        connection.request(
            method,
            path,
            headers={
                "Accept": "application/json",
                auth_header: f"Bearer {token}",
                "User-Agent": "fx-harbor-contract-probe/2",
            },
        )
        response = connection.getresponse()
        body = b"" if method == "HEAD" or (
            method == "CONNECT" and 200 <= response.status < 300
        ) else response.read(4096)
        result["status"] = response.status
        selected_headers = {
            name.lower(): value
            for name, value in response.getheaders()
            if name.lower()
            in {
                "allow",
                "content-type",
                "location",
                "proxy-authenticate",
                "server",
                "via",
                "x-powered-by",
            }
        }
        result["headers"] = selected_headers
        text = body.decode("utf-8", "replace").replace(token, "[REDACTED]")
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict) and isinstance(parsed.get("paths"), dict):
            result["openapi_paths"] = sorted(parsed["paths"])
        elif text:
            result["body_preview"] = text[:1000]
    except (OSError, http.client.HTTPException) as exc:
        result["error"] = type(exc).__name__
    finally:
        connection.close()
    return result


def _token_metadata(token: str) -> dict[str, object]:
    """Return routing-relevant JWT metadata without persisting the credential."""

    parts = token.split(".")
    if len(parts) != 3:
        return {"format": "opaque", "length": len(token)}

    decoded: list[dict[str, object]] = []
    for encoded in parts[:2]:
        try:
            padding = "=" * (-len(encoded) % 4)
            value = json.loads(
                base64.urlsafe_b64decode(encoded + padding).decode("utf-8")
            )
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            return {"format": "jwt-like", "decodable": False}
        if not isinstance(value, dict):
            return {"format": "jwt-like", "decodable": False}
        decoded.append(value)

    header, payload = decoded
    safe_claims = {
        key: payload[key]
        for key in ("aud", "iss", "provider", "model", "target")
        if key in payload and isinstance(payload[key], (str, int, float, bool))
    }
    return {
        "format": "jwt",
        "algorithm": header.get("alg") if isinstance(header.get("alg"), str) else None,
        "header_keys": sorted(header),
        "claim_keys": sorted(payload),
        "routing_claims": safe_claims,
    }


def _validated_upstream(value: str) -> SplitResult:
    if not value:
        raise ValueError("HOSTED_INFERENCE_URL is empty")
    parsed = urlsplit(value)
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("HOSTED_INFERENCE_URL must not contain user information")
    if parsed.fragment:
        raise ValueError("HOSTED_INFERENCE_URL must not contain a fragment")
    if parsed.hostname is None:
        raise ValueError("HOSTED_INFERENCE_URL must contain a hostname")
    if parsed.scheme == "https":
        return parsed
    if parsed.scheme == "http" and _is_loopback(parsed.hostname):
        return parsed
    raise ValueError("HOSTED_INFERENCE_URL must use HTTPS")


def _is_loopback(host: str) -> bool:
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _parse_request_head(
    raw_head: bytes,
) -> tuple[str, str, list[tuple[str, str]]]:
    try:
        lines = raw_head.decode("iso-8859-1").split("\r\n")
        method, target, version = lines[0].split(" ", 2)
    except (UnicodeDecodeError, ValueError) as exc:
        raise ValueError("invalid FX gateway HTTP request") from exc
    if version != "HTTP/1.1":
        raise ValueError("FX gateway request must use HTTP/1.1")
    if method not in {"POST", "GET"}:
        raise ValueError("unsupported FX gateway HTTP method")
    parsed_target = urlsplit(target)
    if parsed_target.scheme or parsed_target.netloc or not parsed_target.path.startswith("/"):
        raise ValueError("FX gateway request must use an origin-form target")

    headers: list[tuple[str, str]] = []
    for line in lines[1:]:
        if not line:
            break
        if ":" not in line:
            raise ValueError("invalid FX gateway HTTP header")
        name, value = line.split(":", 1)
        name = name.strip()
        if not name:
            raise ValueError("invalid FX gateway HTTP header name")
        headers.append((name, value.strip()))
    return method, target, headers


def _content_length(headers: Iterable[tuple[str, str]]) -> int:
    values = [value for name, value in headers if name.lower() == "content-length"]
    if not values:
        return 0
    if len(set(values)) != 1:
        raise ValueError("conflicting FX gateway Content-Length headers")
    try:
        length = int(values[0], 10)
    except ValueError as exc:
        raise ValueError("invalid FX gateway Content-Length") from exc
    if length < 0:
        raise ValueError("invalid FX gateway Content-Length")
    return length


def _upstream_request_head(
    *,
    method: str,
    request_target: str,
    upstream: SplitResult,
    token: str,
    headers: Iterable[tuple[str, str]],
    content_length: int,
) -> bytes:
    target = _join_upstream_target(upstream, request_target)
    default_port = 443 if upstream.scheme == "https" else 80
    port = upstream.port or default_port
    host = upstream.hostname or ""
    host_header = host if port == default_port else f"{host}:{port}"

    output = [
        f"{method} {target} HTTP/1.1",
        f"Host: {host_header}",
        f"Authorization: Bearer {token}",
    ]
    for name, value in headers:
        normalized = name.lower()
        if normalized in _HOP_BY_HOP_HEADERS:
            continue
        if normalized in {"host", "authorization", "content-length"}:
            continue
        output.append(f"{name}: {value}")
    output.extend(
        [
            f"Content-Length: {content_length}",
            "Connection: close",
            "",
            "",
        ]
    )
    return "\r\n".join(output).encode("iso-8859-1")


def _join_upstream_target(upstream: SplitResult, request_target: str) -> str:
    incoming = urlsplit(request_target)
    base_path = upstream.path.rstrip("/")
    suffix = incoming.path.lstrip("/")
    path = f"{base_path}/{suffix}" if suffix else (base_path or "/")
    queries = [value for value in (upstream.query, incoming.query) if value]
    if queries:
        return f"{path}?{'&'.join(queries)}"
    return path


async def _relay_exactly(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    byte_count: int,
) -> None:
    remaining = byte_count
    while remaining:
        chunk = await reader.read(min(remaining, _STREAM_CHUNK_BYTES))
        if not chunk:
            raise asyncio.IncompleteReadError(b"", remaining)
        writer.write(chunk)
        remaining -= len(chunk)


async def _write_bad_gateway(writer: asyncio.StreamWriter) -> None:
    body = b'{"error":"Harbor hosted inference proxy failed"}'
    writer.write(
        b"HTTP/1.1 502 Bad Gateway\r\n"
        b"Content-Type: application/json\r\n"
        + f"Content-Length: {len(body)}\r\n".encode("ascii")
        + b"Connection: close\r\n\r\n"
        + body
    )
    try:
        await writer.drain()
    except (ConnectionError, OSError):
        pass


async def _wait_closed(writer: asyncio.StreamWriter) -> None:
    try:
        await writer.wait_closed()
    except (ConnectionError, OSError):
        pass
