import httpx


def test_hello_unauthorized(nginx_server: str):
    response = httpx.get(f"{nginx_server}/hello.txt")
    assert response.status_code == 403

    response = httpx.get(
        f"{nginx_server}/hello.txt", headers={"Authorization": "Bearer blah"}
    )
    assert response.status_code == 403


def test_hello(nginx_server: str, wlcg_read_header: dict[str, str]):
    response = httpx.get(f"{nginx_server}/hello.txt", headers=wlcg_read_header)
    assert response.status_code == 200
    assert response.text == "Hello, world!"
