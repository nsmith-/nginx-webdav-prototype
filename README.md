# Nginx WebDAV Prototype

This project prototypes an Nginx server deployed in a Podman container with a protected directory that supports read-write access using WebDAV, authenticated with OpenIDConnect bearer tokens signed by the CMS IAM.

Relevant docs:

- Nginx WebDAV module http://nginx.org/en/docs/http/ngx_http_dav_module.html and [source](https://github.com/nginx/nginx/blob/master/src/http/modules/ngx_http_dav_module.c)
- lua-resty-openidc https://github.com/zmartzone/lua-resty-openidc

## Setup Instructions

1. Clone the repository to your local machine.
2. Navigate to the project directory.
3. Build and run the Podman containers using the following command:

```sh
podman build -t nginx-webdav \
   ./nginx -f nginx.dockerfile

mkdir data
echo "Hello, world!" > data/hello.txt

podman run -d -p 8080:8080 \
   -v ./nginx/conf.d:/etc/nginx/conf.d:Z \
   -v ./nginx/lua:/etc/nginx/lua:Z \
   -v ./data:/var/www/webdav:Z \
   nginx-webdav
```

You can reload the configuration with `podman exec <name> nginx -s reload`

## Testing

You can run a suite of tests if you have podman and a python virtual environment set up with:

```bash
pip install -r tests/requirements.txt
pytest
```

For testing with CMS auth, first, get a valid token, e.g. with [oidc-agent](https://wlcg-authz-wg.github.io/wlcg-authz-docs/token-based-authorization/oidc-agent/). Set it's value to the `$BEARER_TOKEN` environment variable, e.g. with `export BEARER_TOKEN=$(oidc-token tokenname)`.

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
