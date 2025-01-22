local function third_party_pull(source_uri, destination_localpath)
    local httpc = require("resty.http").new()

    -- First establish a connection
    local scheme, host, port, path = unpack(httpc:parse_uri(source_uri))
    local ok, err, ssl_session = httpc:connect({
        scheme = scheme,
        host = host,
        port = port,
        ssl_verify = false, -- FIXME: disable SSL verification for testing
    })
    if not ok then
        ngx.status = 500
        ngx.say("connection to ", source_uri, " failed: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local headers = {
        ["Host"] = host,
    }
    if ngx.var.http_transferheaderauthorization then
        headers["Authorization"] = ngx.var.http_transferheaderauthorization
    end
    local res, err = httpc:request({
        path = path,
        headers = headers,
    })
    if not res then
        ngx.status = 500
        ngx.say("request failed: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- TODO: break this into a function and make it recursive
    if res.status == 302 then
        return third_party_pull(res.headers["Location"], destination_localpath)
    end

    if res.status ~= 200 then
        ngx.status = res.status
        ngx.say("request failed: ", res.reason)
        ngx.exit(res.status)
    end

    -- At this point, the status and headers will be available to use in the `res`
    -- table, but the body and any trailers will still be on the wire.
    local file, err = io.open(destination_localpath, "w+b")
    if file == nil then
        ngx.status = 500
        ngx.say("failed to open destination file: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR) 
    end

    -- We can use the `body_reader` iterator, to stream the body according to our
    -- desired buffer size.
    local reader = res.body_reader
    local buffer_size = 8192

    repeat
        local buffer, err = reader(buffer_size)
        if err then
            ngx.log(ngx.ERR, err)
            break
        end

        if buffer then
            -- TODO: build checksum
            -- can use LuaJIT FFI to call C function
            -- https://stackoverflow.com/questions/53805913/how-to-define-c-functions-with-luajit
            -- e.g. a C function for https://en.wikipedia.org/wiki/Adler-32
            file:write(buffer)
        end
    until not buffer

    file:close()

    local ok, err = httpc:set_keepalive()
    if not ok then
        ngx.status = 500
        ngx.say("failed to set keepalive: ", err)
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR) 
    end
end

local opts = {
    -- discovery = "https://cms-auth.web.cern.ch/.well-known/openid-configuration",
    -- this is the public key from the above provider
    public_key = [[-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnAO8vabKkITjjDht2dL+
GCB+zakuHsbwC6xaQWZpVePm3t9o0RO5r+fjgqux5iCPJSTr26QDvpdQ6aGmVWPz
W7oGKyEYCGwMxK8o69jIfDBkeXPQdWYAu5lWmoY3tm322o65s5luMKEexEwbzgj8
lFHxGGVK6xj3Vb0ky/bJPNOa2lV3SziD1PuiqoTUbkcI8+pUXMqhkvvVhtLjmhOW
nYRpXnJvRswePD3s0nSYwAWr7TyRm5r/UCr5MoZpWSUg3eBKw5YFiWY8EIBu70Ys
I0VY97z1mRO4S1TXwUwzr3NlB3JPmnJUKGRlh6ZceKnqGQWieS87rOn1aEUWNcxa
LwIDAQAB
-----END PUBLIC KEY-----]],
}
-- call bearer_jwt_verify for OAuth 2.0 JWT validation
local res, err = require("resty.openidc").bearer_jwt_verify(opts)

if err or not res then
    ngx.status = 403
    ngx.say(err and err or "no access_token provided")
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

-- From https://github.com/WLCG-AuthZ-WG/common-jwt-profile/blob/master/profile.md#capability-based-authorization-scope

-- storage.read: Read data. Only applies to “online” resources such as disk (as opposed to “nearline” such as tape where the stage authorization should be used in addition).
local is_read = ngx.var.request_method == "GET" or ngx.var.request_method == "HEAD"
if string.find(res.scope, "storage.read:/") == nil and is_read then
    ngx.status = 403
    ngx.say("no permission to read this resource")
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

-- storage.create: Upload data. This includes renaming files if the destination file does not already exist. This capability includes the creation of directories and subdirectories at the specified path, and the creation of any non-existent directories required to create the path itself. This authorization does not permit overwriting or deletion of stored data. The driving use case for a separate storage.create scope is to enable the stage-out of data from jobs on a worker node.
local is_create = ngx.var.request_method == "PUT" or ngx.var.request_method == "COPY" or ngx.var.request_method == "MKCOL"
-- FIXME: using read permission for testing
if string.find(res.scope, "storage.read:/") == nil and is_create then
    ngx.status = 403
    ngx.say("no permission to create this resource")
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

if ngx.var.request_method == "COPY" then
    -- The COPY method is supported by ngx_http_dav_module but only for files on the same server.
    -- We intercept the method here to support third-party push copy.
    if not ngx.var.http_source then
        ngx.status = 400
        ngx.say("no source provided")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end

    if ngx.var.http_destination then
        ngx.status = 501
        ngx.say("third-party push copy not implemented")
        ngx.exit(ngx.HTTP_NOT_IMPLEMENTED)
    end

    -- TODO: better way to find the local file location?
    third_party_pull(ngx.var.http_source, "/var/www" .. ngx.var.request_uri)

    -- At this point, the connection will either be safely back in the pool, or closed.
    ngx.exit(ngx.HTTP_OK)
end

-- storage.modify: Change data. This includes renaming files, creating new files, and writing data. This permission includes overwriting or replacing stored data in addition to deleting or truncating data. This is a strict superset of storage.create.
local is_modify = ngx.var.request_method == "DELETE" or ngx.var.request_method == "MOVE"
if string.find(res.scope, "storage.read:/") == nil and is_modify then
    ngx.status = 403
    ngx.say("no permission to modify this resource")
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

-- storage.stage: Read the data, potentially causing data to be staged from a nearline resource to an online resource. This is a superset of storage.read.
-- TODO: implement this