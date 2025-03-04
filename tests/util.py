import httpx


def assert_status(response: httpx.Response, status_code: httpx.codes):
    assert response.status_code == status_code, (
        f"{response.status_code} != {status_code}\nText: {response.text}"
    )