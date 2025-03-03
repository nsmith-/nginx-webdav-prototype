import json
import os
import shutil
import subprocess
import time
import uuid
from dataclasses import dataclass
from typing import Iterator

import httpx
import jwt
import pytest
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa


@dataclass
class MockIdP:
    public_key_pem: str
    private_key: rsa.RSAPrivateKey
    iss: str

    def encode_jwt(self, payload: dict) -> str:
        return jwt.encode(payload, self.private_key, algorithm="RS256")


@pytest.fixture(scope="module")
def oidc_mock_idp() -> Iterator[MockIdP]:
    private_key = rsa.generate_private_key(
        public_exponent=65537, key_size=2048, backend=default_backend()
    )
    public_key = private_key.public_key()

    public_pem = public_key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    yield MockIdP(
        public_key_pem=public_pem.decode("ascii"),
        private_key=private_key,
        iss="https://mock-idp.com",
    )


@pytest.fixture(scope="module")
def wlcg_read_header(oidc_mock_idp: MockIdP) -> dict[str, str]:
    not_before = int(time.time())
    issued_at = not_before
    expires = not_before + 4 * 3600
    token = {
        "wlcg.ver": "1.0",
        "sub": "test_subject",
        "aud": "https://wlcg.cern.ch/jwt/v1/any",
        "nbf": not_before,
        "scope": "openid offline_access storage.read:/",
        "iss": "oidc_mock_idp.iss",
        "exp": expires,
        "iat": issued_at,
        "jti": str(uuid.uuid4()),
        "client_id": "test_client_id",
    }
    bt = oidc_mock_idp.encode_jwt(token)
    return {"Authorization": f"Bearer {bt}"}


@pytest.fixture(scope="module")
def nginx_server(oidc_mock_idp: MockIdP) -> Iterator[str]:
    # Make sure we are in the right place: one up from tests/
    assert os.getcwd() == os.path.dirname(os.path.dirname(__file__))

    # see nginx/lua/config.lua for schema
    config = {
        "openidc_pubkey": oidc_mock_idp.public_key_pem,
    }
    with open("nginx/lua/config.json", "w") as f:
        json.dump(config, f)

    # Build podman container
    subprocess.check_call(
        ["podman", "build", "-t", "nginx-webdav", "nginx", "-f", "nginx.dockerfile"]
    )

    # Make initial data
    os.makedirs("data")
    with open("data/hello.txt", "w") as f:
        f.write("Hello, world!")

    # Start podman container
    container_id =subprocess.check_output(
        [
            "podman",
            "run",
            "-d",
            "-p",
            "8080:8080",
            "-v",
            "./nginx/conf.d:/etc/nginx/conf.d:Z",
            "-v",
            "./nginx/lua:/etc/nginx/lua:Z",
            "-v",
            "./data:/var/www/webdav:Z",
            "nginx-webdav",
        ]
    ).decode().strip()

    # Wait for the container to start
    for _ in range(10):
        try:
            time.sleep(0.1)
            httpx.get("http://localhost:8080/")
            break
        except httpx.HTTPError:
            pass

    yield "http://localhost:8080/webdav"

    # Dump container logs
    subprocess.check_call(["podman", "logs", container_id])

    # Stop podman container and clean up
    subprocess.check_call(["podman", "stop", container_id])
    subprocess.check_call(["podman", "rm", container_id])
    shutil.rmtree("data")
    os.remove("nginx/lua/config.json")
