import httpx

from .util import assert_status


def test_hello_unauthorized(nginx_server: str):
    response = httpx.get(f"{nginx_server}/hello.txt")
    assert_status(response, httpx.codes.UNAUTHORIZED)

    response = httpx.get(
        f"{nginx_server}/hello.txt", headers={"Authorization": "Bearer blah"}
    )
    assert_status(response, httpx.codes.UNAUTHORIZED)


def test_hello(nginx_server: str, wlcg_read_header: dict[str, str]):
    response = httpx.get(f"{nginx_server}/hello.txt", headers=wlcg_read_header)
    assert_status(response, httpx.codes.OK)
    assert response.text == "Hello, world!"
