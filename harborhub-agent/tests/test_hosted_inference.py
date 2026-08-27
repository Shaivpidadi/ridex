from __future__ import annotations

import asyncio
import unittest

from fx_harbor_agent.hosted_inference import HostedInferenceProxy


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


if __name__ == "__main__":
    unittest.main()
