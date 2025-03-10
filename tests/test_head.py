import zlib

import httpx

from .util import assert_status


def test_head_unauthorized(nginx_server: str):
    response = httpx.head(f"{nginx_server}/hello.txt")
    assert_status(response, httpx.codes.UNAUTHORIZED)

    response = httpx.head(
        f"{nginx_server}/hello.txt", headers={"Authorization": "Bearer blah"}
    )
    assert_status(response, httpx.codes.UNAUTHORIZED)


def test_head(nginx_server: str, wlcg_read_header: dict[str, str]):
    response = httpx.head(f"{nginx_server}/hello.txt", headers=wlcg_read_header)
    assert_status(response, httpx.codes.OK)
    assert response.headers["Content-Length"] == "13"
    assert response.text == ""


def test_head_adler32(nginx_server: str, wlcg_read_header: dict[str, str]):
    headers = dict(wlcg_read_header)
    headers["Want-Digest"] = "adler32"
    response = httpx.head(f"{nginx_server}/hello.txt", headers=headers)
    assert_status(response, httpx.codes.OK)
    assert response.headers["Content-Length"] == "13"
    adler32 = zlib.adler32(b"Hello, world!")
    assert response.headers["Digest"] == f"adler32={adler32:08x}"
