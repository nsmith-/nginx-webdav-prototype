import logging
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread
from typing import Iterable

import httpx
import pytest

from .util import assert_status

logger = logging.getLogger("RequestHandler")


class RequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/hello.txt":
            if "Authorization" not in self.headers:
                logger.info("No Authorization header")
                self.send_response(httpx.codes.UNAUTHORIZED)
                self.end_headers()
                return
            if self.headers["Authorization"] != "Bearer opensesame":
                logger.info("Invalid Authorization header")
                self.send_response(httpx.codes.FORBIDDEN)
                self.end_headers()
                return
            self.send_response(httpx.codes.OK)
            data = b"Hello, world!"
            nbytes = len(data)
            self.send_header("Content-type", "application/octet-stream")
            self.send_header("Content-length", str(nbytes))
            self.end_headers()
            self.wfile.write(data)
            logger.info("GET /hello.txt 200")
            return

        self.send_response(httpx.codes.NOT_FOUND)
        self.end_headers()
        logger.info(f"GET {self.path} 404")


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
    assert_status(response, httpx.codes.GATEWAY_TIMEOUT)


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
    assert_status(response, httpx.codes.OK)

    response = httpx.get(dst, headers=wlcg_create_header)
    assert_status(response, httpx.codes.OK)
    assert response.text == "Hello, world!"
