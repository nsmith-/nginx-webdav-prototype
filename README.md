# Nginx WebDAV Prototype

This project prototypes an Nginx server deployed in a Podman container with a protected directory that supports read-write access using WebDAV, authenticated with OpenIDConnect bearer tokens signed by the CMS IAM.

Relevant docs:
- lua-nginx-module https://github.com/openresty/lua-nginx-module
- lua-resty-openidc https://github.com/zmartzone/lua-resty-openidc

## Installation instructions

A docker image is available:
```sh
docker pull ghcr.io/hepcdn/nginx-webdav:latest
```
The image expects the main data directory to be bind-mounted at `/var/www/webdav`.
It is configurable via several environment variables:
- SERVER_NAME (default: localhost)
- USE_SSL (true/false, default: false)
- PORT (default: 8080)
- SSL_HOST_CERT (default: /etc/grid-security/hostcert.pem)
- SSL_HOST_KEY (default: /etc/grid-security/hostkey.pem)
- SSL_CERT_DIR (default: /etc/grid-security/certificates)
- DEBUG (true/false, default: false)
See `nginx/docker-entrypoint.sh` for further details.

## Development Instructions

1. Clone the repository to your local machine.
2. Navigate to the project directory.
3. Build and run the Podman containers using the following command:

```sh
podman build -t nginx-webdav -f nginx/nginx.dockerfile ./nginx

mkdir data
echo 'Hello, world!' > data/hello.txt

podman run -d -p 8080:8080 \
   -v ./nginx/conf.d:/etc/nginx/conf.d:Z \
   -v ./nginx/lua:/etc/nginx/lua:Z \
   -v ./data:/var/www/webdav:Z \
   -e DEBUG=true \
   nginx-webdav
```

You can reload the configuration with `podman exec <name> nginx -s reload`

### Testing

You can run a suite of tests if you have podman and a python virtual environment set up with:

```bash
pip install -r tests/requirements.txt
pytest
```

## Usage examples

For usage with CMS auth, first, get a valid token, e.g. with [oidc-agent](https://wlcg-authz-wg.github.io/wlcg-authz-docs/token-based-authorization/oidc-agent/). Set it's value to the `$BEARER_TOKEN` environment variable, e.g. with `export BEARER_TOKEN=$(oidc-token tokenname)`.

### Read a file

```sh
curl -H "Authorization: Bearer $BEARER_TOKEN" http://localhost:8080/webdav/hello.txt
```

### Write a file

```sh
curl -H "Authorization: Bearer $BEARER_TOKEN" -T README.md http://localhost:8080/webdav/
```

### Third-party copy

```sh
curl -H "TransferHeaderAuthorization: Bearer $BEARER_TOKEN" \
   -H "Authorization: Bearer $BEARER_TOKEN" \
   -H 'Source: https://cmsdcadisk.fnal.gov:2880/dcache/uscmsdisk/store/test/loadtest/source/T1_US_FNAL_Disk/urandom.270MB.file0000' \
   -X 'COPY' http://localhost:8080/webdav/urandom.270MB.file0000
```
