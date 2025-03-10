import logging
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread
from typing import Iterable, Iterator

import httpx
import pytest

from .util import assert_status

logger = logging.getLogger("RequestHandler")


class RequestHandler(BaseHTTPRequestHandler):
    def _auth(self):
        if "Authorization" not in self.headers:
            logger.info("No Authorization header")
            self.send_response(httpx.codes.UNAUTHORIZED)
            self.end_headers()
            return False
        if self.headers["Authorization"] != "Bearer opensesame":
            logger.info("Invalid Authorization header")
            self.send_response(httpx.codes.FORBIDDEN)
            self.end_headers()
            return False
        return True

    def do_GET(self):
        if not self._auth():
            return

        if self.path == "/hello.txt":
            code = httpx.codes.OK
            data = b"Hello, world!"
            nbytes = len(data)
            self.send_response(code)
            self.send_header("Content-type", "application/octet-stream")
            self.send_header("Content-length", str(nbytes))
            self.send_header("Digest", "adler32=205e048a")
            self.end_headers()
            self.wfile.write(data)
        elif self.path.startswith("/bigdata.bin"):
            code = httpx.codes.OK
            nchunks = 10
            chunk = b"Hello, world!" * 1000
            nbytes = len(chunk) * nchunks
            adler32 = 0x37F631F0
            self.send_response(httpx.codes.OK)
            self.send_header("Content-type", "application/octet-stream")
            self.send_header("Content-length", str(nbytes))
            if "adler32" in self.path:
                self.send_header("Digest", f"adler32={adler32:08x}")
            self.end_headers()
            for _ in range(nchunks):
                self.wfile.write(chunk)
                if "slow" in self.path:
                    self.wfile.flush()
                    time.sleep(1)
        else:
            code = httpx.codes.NOT_FOUND
            self.send_response(code)
            self.end_headers()

        logger.info(f"GET {self.path} {code}")


@pytest.fixture(scope="module")
def peer_server() -> Iterable[str]:
    server_address = ("", 8081)
    httpd = HTTPServer(server_address, RequestHandler)
    thread = Thread(target=httpd.serve_forever)
    thread.start()

    yield "http://host.containers.internal:8081"

    httpd.shutdown()
    thread.join()


def test_tpc_pull_nonexistent(
    nginx_server: str,
    wlcg_create_header: dict[str, str],
    caplog,
):
    caplog.set_level(logging.INFO)

    src = "http://nonexistent.host:8081/nonexistent.txt"
    dst = f"{nginx_server}/nonexistent_tpc_pull.txt"

    headers = dict(wlcg_create_header)
    headers["Source"] = src
    headers["TransferHeaderAuthorization"] = "Bearer opensesame"
    response = httpx.request("COPY", dst, headers=headers)
    assert_status(response, httpx.codes.ACCEPTED)
    assert response.text.startswith(
        "failure: connection to nonexistent.host:8081 failed:"
    )


def test_tpc_pull(
    nginx_server: str,
    wlcg_create_header: dict[str, str],
    peer_server: str,
    caplog,
):
    caplog.set_level(logging.INFO)

    src = f"{peer_server}/hello.txt"
    dst = f"{nginx_server}/hello_tpc_pull.txt"

    headers = dict(wlcg_create_header)
    response = httpx.request("COPY", dst, headers=headers)
    assert_status(response, httpx.codes.BAD_REQUEST)

    headers["Source"] = src
    response = httpx.request("COPY", dst, headers=headers)
    assert_status(response, httpx.codes.UNAUTHORIZED)

    headers["TransferHeaderAuthorization"] = "Bearer not correct"
    response = httpx.request("COPY", dst, headers=headers)
    assert_status(response, httpx.codes.FORBIDDEN)

    headers["TransferHeaderAuthorization"] = "Bearer opensesame"
    response = httpx.request("COPY", dst, headers=headers)
    assert_status(response, httpx.codes.ACCEPTED)
    lines = response.text.splitlines()
    assert lines[-1] == "success: Created"

    response = httpx.get(dst, headers=wlcg_create_header)
    assert_status(response, httpx.codes.OK)
    assert response.text == "Hello, world!"


def test_tpc_pull_bigdata(
    nginx_server: str,
    wlcg_create_header: dict[str, str],
    peer_server: str,
    caplog,
):
    caplog.set_level(logging.INFO)

    src = f"{peer_server}/bigdata.bin"
    dst = f"{nginx_server}/bigdata_tpc_pull.bin"

    headers = dict(wlcg_create_header)
    headers["Source"] = src
    headers["TransferHeaderAuthorization"] = "Bearer opensesame"

    response = httpx.request("COPY", dst, headers=headers)
    assert response.status_code == httpx.codes.ACCEPTED
    assert (
        response.text.strip()
        == "failure: adler32 checksum mismatch: source (missing) desination 37f631f0"
    )

    headers["RequireChecksumVerification"] = "false"
    response = httpx.request("COPY", dst, headers=headers)
    assert response.status_code == httpx.codes.ACCEPTED
    lines = response.text.splitlines()
    assert lines[-1] == "success: Created"

    del headers["RequireChecksumVerification"]
    headers["Source"] = f"{peer_server}/bigdata.bin.adler32"
    response = httpx.request("COPY", dst, headers=headers)
    assert response.status_code == httpx.codes.ACCEPTED
    assert response.text.strip() == "success: Created"

    response = httpx.get(dst, headers=wlcg_create_header)
    assert_status(response, httpx.codes.OK)
    assert response.content == b"Hello, world!" * 10_000


def test_tpc_pull_perfmarkers(
    nginx_server: str,
    wlcg_create_header: dict[str, str],
    peer_server: str,
    caplog,
):
    caplog.set_level(logging.INFO)

    src = f"{peer_server}/bigdata.bin.adler32.slow"
    dst = f"{nginx_server}/bigdata_tpc_pull.bin"

    headers = dict(wlcg_create_header)
    headers["Source"] = src
    headers["TransferHeaderAuthorization"] = "Bearer opensesame"

    def read_permarker(lines: Iterator[str]):
        data: dict[str, str] = {}
        while True:
            line = next(lines)
            if line == "End":
                yield data
                break
            if ": " not in line:
                raise RuntimeError(f"Invalid line: {line}")
            key, value = line.split(": ", 1)
            data[key.lstrip()] = value

    def read_response(lines: Iterator[str]):
        while True:
            line = next(lines)
            if line == "Perf Marker":
                yield from read_permarker(lines)
            elif line == "success: Created":
                yield {"success": "Created"}
                break
            else:
                raise RuntimeError(f"Unexpected line: {line}")

    start = time.monotonic()
    markers = []
    with httpx.stream("COPY", dst, headers=headers, timeout=10) as response:
        assert response.status_code == httpx.codes.ACCEPTED
        for data in read_response(response.iter_lines()):
            if "Stripe Transfer Time" in data:
                assert (
                    float(data["Stripe Transfer Time"]) - (time.monotonic() - start)
                    < 0.1
                )
            markers.append(data)
    assert len(markers) >= 2
    assert "success" in markers[-1]
