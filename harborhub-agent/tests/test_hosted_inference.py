from __future__ import annotations

import asyncio
import base64
import json
import unittest

from fx_harbor_agent.hosted_inference import (
    HostedInferenceProxy,
    probe_hosted_inference,
)


class HostedInferenceProxyTests(unittest.IsolatedAsyncioTestCase):
    async def test_forwards_exact_hosted_path_token_headers_body_and_stream(self) -> None:
        captured: dict[str, object] = {}

        async def upstream(
            reader: asyncio.StreamReader,
            writer: asyncio.StreamWriter,
        ) -> None:
            head = await reader.readuntil(b"\r\n\r\n")
            lines = head.decode("iso-8859-1").split("\r\n")
            headers = {
                name.lower(): value.strip()
                for line in lines[1:]
                if line
                for name, value in [line.split(":", 1)]
            }
            body = await reader.readexactly(int(headers["content-length"]))
            captured.update(
                request_line=lines[0],
                headers=headers,
                body=body,
            )
            response_chunks = [b"data: first\n\n", b"data: second\n\n"]
            response_body = b"".join(response_chunks)
            writer.write(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/event-stream\r\n"
                + f"Content-Length: {len(response_body)}\r\n".encode("ascii")
                + b"Connection: close\r\n\r\n"
            )
            for chunk in response_chunks:
                writer.write(chunk)
                await writer.drain()
            writer.close()
            await writer.wait_closed()

        upstream_server = await asyncio.start_server(upstream, "127.0.0.1", 0)
        upstream_port = upstream_server.sockets[0].getsockname()[1]
        try:
            async with HostedInferenceProxy(
                f"http://127.0.0.1:{upstream_port}/targets?trial=one",
                "hosted-token",
            ) as proxy:
                proxy_port = int(proxy.local_url.split(":")[2].split("/")[0])
                reader, writer = await asyncio.open_connection("127.0.0.1", proxy_port)
                body = b'{"messages":[{"role":"user","content":"hello"}]}'
                writer.write(
                    b"POST /v3/ai/language-model?stream=true HTTP/1.1\r\n"
                    b"Host: 127.0.0.1\r\n"
                    b"Authorization: Bearer provider-key-must-not-pass\r\n"
                    b"Content-Type: application/json\r\n"
                    b"ai-language-model-id: openai/gpt-5.6-sol\r\n"
                    + f"Content-Length: {len(body)}\r\n".encode("ascii")
                    + b"Connection: close\r\n\r\n"
                    + body
                )
                await writer.drain()
                response = await reader.read()
                writer.close()
                await writer.wait_closed()
        finally:
            upstream_server.close()
            await upstream_server.wait_closed()

        self.assertEqual(
            captured["request_line"],
            "POST /targets/v3/ai/language-model?trial=one&stream=true HTTP/1.1",
        )
        headers = captured["headers"]
        assert isinstance(headers, dict)
        self.assertEqual(headers["authorization"], "Bearer hosted-token")
        self.assertEqual(headers["ai-language-model-id"], "openai/gpt-5.6-sol")
        self.assertEqual(captured["body"], body)
        self.assertIn(b"HTTP/1.1 200 OK", response)
        self.assertTrue(response.endswith(b"data: first\n\ndata: second\n\n"))

    async def test_rejects_non_https_remote_upstream(self) -> None:
        with self.assertRaisesRegex(ValueError, "must use HTTPS"):
            HostedInferenceProxy("http://example.com/targets", "token")

    async def test_rejects_empty_hosted_token(self) -> None:
        with self.assertRaisesRegex(ValueError, "TOKEN is empty"):
            HostedInferenceProxy("https://example.com/targets", "")

    async def test_contract_probe_extracts_paths_without_recording_token(self) -> None:
        request_heads: list[str] = []

        async def upstream(
            reader: asyncio.StreamReader,
            writer: asyncio.StreamWriter,
        ) -> None:
            head = await reader.readuntil(b"\r\n\r\n")
            request_heads.append(head.decode("iso-8859-1"))
            request_line = head.decode("iso-8859-1").split("\r\n", 1)[0]
            method, path, _version = request_line.split(" ", 2)
            if path == "/openapi.json":
                body = b'{"paths":{"/targets/{target_path}":{},"/health":{}}}'
                status = b"200 OK"
            elif method == "CONNECT":
                body = b""
                status = b"407 Proxy Authentication Required"
            else:
                body = b'{"detail":"Not Found"}'
                status = b"404 Not Found"
            writer.write(
                b"HTTP/1.1 "
                + status
                + b"\r\nContent-Type: application/json\r\n"
                + f"Content-Length: {len(body)}\r\n".encode("ascii")
                + b"Connection: close\r\n\r\n"
                + body
            )
            await writer.drain()
            writer.close()
            await writer.wait_closed()

        upstream_server = await asyncio.start_server(upstream, "127.0.0.1", 0)
        upstream_port = upstream_server.sockets[0].getsockname()[1]
        try:
            report = await probe_hosted_inference(
                f"http://127.0.0.1:{upstream_port}/targets",
                "short-lived-secret-token",
            )
        finally:
            upstream_server.close()
            await upstream_server.wait_closed()

        serialized = str(report)
        self.assertNotIn("short-lived-secret-token", serialized)
        openapi_probe = next(
            probe
            for probe in report["probes"]
            if probe["path"] == "/openapi.json"
        )
        self.assertEqual(
            openapi_probe["openapi_paths"],
            ["/health", "/targets/{target_path}"],
        )
        self.assertEqual(len(report["probes"]), 9)
        self.assertTrue(
            any(
                head.startswith("CONNECT ai-gateway.vercel.sh:443 HTTP/1.1")
                and "Proxy-Authorization: Bearer short-lived-secret-token" in head
                for head in request_heads
            )
        )
        self.assertNotIn("short-lived-secret-token", json.dumps(report))

    async def test_contract_probe_reports_safe_jwt_routing_metadata(self) -> None:
        async def upstream(
            reader: asyncio.StreamReader,
            writer: asyncio.StreamWriter,
        ) -> None:
            head = await reader.readuntil(b"\r\n\r\n")
            method = head.decode("iso-8859-1").split(" ", 1)[0]
            status = (
                b"407 Proxy Authentication Required"
                if method == "CONNECT"
                else b"404 Not Found"
            )
            writer.write(
                b"HTTP/1.1 "
                + status
                + b"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            await writer.drain()
            writer.close()
            await writer.wait_closed()

        def encode(value: dict[str, object]) -> str:
            raw = json.dumps(value, separators=(",", ":")).encode()
            return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

        token = ".".join(
            [
                encode({"alg": "HS256", "typ": "JWT"}),
                encode(
                    {
                        "aud": "harbor-gateway",
                        "provider": "vercel_ai_gateway",
                        "target": "ai-gateway.vercel.sh",
                        "sub": "sensitive-trial-id",
                    }
                ),
                "signature-must-not-be-recorded",
            ]
        )
        upstream_server = await asyncio.start_server(upstream, "127.0.0.1", 0)
        upstream_port = upstream_server.sockets[0].getsockname()[1]
        try:
            report = await probe_hosted_inference(
                f"http://127.0.0.1:{upstream_port}/targets",
                token,
            )
        finally:
            upstream_server.close()
            await upstream_server.wait_closed()

        metadata = report["token_metadata"]
        self.assertEqual(metadata["format"], "jwt")
        self.assertEqual(metadata["algorithm"], "HS256")
        self.assertEqual(
            metadata["routing_claims"],
            {
                "aud": "harbor-gateway",
                "provider": "vercel_ai_gateway",
                "target": "ai-gateway.vercel.sh",
            },
        )
        self.assertIn("sub", metadata["claim_keys"])
        self.assertNotIn("sensitive-trial-id", json.dumps(report))
        self.assertNotIn("signature-must-not-be-recorded", json.dumps(report))


if __name__ == "__main__":
    unittest.main()
