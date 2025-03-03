import httpx


def test_crud_file(
    nginx_server: str,
    wlcg_create_header: dict[str, str],
    wlcg_modify_header: dict[str, str],
):
    path = f"{nginx_server}/test_new.txt"
    data = "Hello, world!" * 1000

    response = httpx.put(path, headers=wlcg_create_header, content=data)
    assert response.status_code == httpx.codes.CREATED

    response = httpx.get(path, headers=wlcg_create_header)
    assert response.status_code == httpx.codes.OK
    assert response.text == data

    response = httpx.put(path, headers=wlcg_create_header, content=data + "plus more")
    # TODO: this should be FORBIDDEN, but allowed for wlcg_modify_header
    assert response.status_code == httpx.codes.NO_CONTENT

    response = httpx.get(path, headers=wlcg_create_header)
    assert response.status_code == httpx.codes.OK
    assert response.text == data + "plus more"

    # TODO: once the above is fixed, this should be uncommented
    # response = httpx.put(path, headers=wlcg_create_header, data=data + "with some extra data")
    # assert response.status_code == httpx.codes.CREATED

    response = httpx.delete(path, headers=wlcg_create_header)
    # TODO: this should be FORBIDDEN, but allowed for wlcg_modify_header
    assert response.status_code == httpx.codes.NO_CONTENT

    # TODO: once the above is fixed, this should be uncommented
    # response = httpx.delete(path, headers=wlcg_modify_header)
    # assert response.status_code == httpx.codes.NO_CONTENT

    response = httpx.get(path, headers=wlcg_create_header)
    assert response.status_code == httpx.codes.NOT_FOUND
