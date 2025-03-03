local ngx = require "ngx"
local openidc = require "resty.openidc"
local config = require "config"
local http = require "resty.http"

local function third_party_pull(source_uri, destination_localpath)
    local httpc = http.new()

    -- First establish a connection
    local scheme, host, port, path = table.unpack(httpc:parse_uri(source_uri))
    local ok, err, ssl_session = httpc:connect({
        scheme = scheme,
        host = host,
        port = port,
        ssl_verify = false, -- FIXME: disable SSL verification for testing
    })
    if not ok then
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say("connection to ", source_uri, " failed: ", err)
        return ngx.exit(ngx.OK)
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
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say("request failed: ", err)
        return ngx.exit(ngx.OK)
    end

    -- TODO: count redirects and stop after some limit
    if res.status == 302 then
        return third_party_pull(res.headers["Location"], destination_localpath)
    end

    if res.status ~= 200 then
        ngx.status = res.status
        ngx.say("request failed: ", res.reason)
        return ngx.exit(res.status)
    end

    -- At this point, the status and headers will be available to use in the `res`
    -- table, but the body and any trailers will still be on the wire.
    local file, err = io.open(destination_localpath, "w+b")
    if file == nil then
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say("failed to open destination file: ", err)
        return ngx.exit(ngx.OK)
    end

    -- We can use the `body_reader` iterator, to stream the body according to our desired buffer size.
    local reader = res.body_reader
    local buffer_size = 16*1024

    repeat
        local buffer, err = reader(buffer_size)
        local closed = err:sub(1, 6) == "closed"
        if err and not closed then
            ngx.log(ngx.ERR, err)
            break
        end

        if buffer then
            -- TODO: build checksum
            -- can use LuaJIT FFI to call C function
            -- https://stackoverflow.com/questions/53805913/how-to-define-c-functions-with-luajit
            -- e.g. a C function for https://en.wikipedia.org/wiki/Adler-32
            -- libz has this function
            -- TODO: coroutine https://www.lua.org/manual/5.1/manual.html#2.11
            file:write(buffer)
        end

        if closed then
            break
        end
    until not buffer

    file:close()

    -- this allows the connection to be reused by other requests
    ok, err = httpc:set_keepalive()
    if not ok then
        -- TODO: is this a fatal error?
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say("failed to set keepalive: ", err)
        return ngx.exit(ngx.OK)
    end
end

local opts = {
    public_key = config.data.openidc_pubkey,
}
-- call bearer_jwt_verify for OAuth 2.0 JWT validation
local res, err = openidc.bearer_jwt_verify(opts)

if err or not res then
    ngx.status = ngx.HTTP_UNAUTHORIZED
    ngx.say(err and err or "no access_token provided")
    return ngx.exit(ngx.OK)
end

-- From https://github.com/WLCG-AuthZ-WG/common-jwt-profile/blob/master/profile.md#capability-based-authorization-scope

-- storage.read: Read data. Only applies to “online” resources such as disk (as opposed to “nearline” such as tape where the stage authorization should be used in addition).
local is_read = ngx.var.request_method == "GET" or ngx.var.request_method == "HEAD"
if string.find(res.scope, "storage.read:/") == nil and is_read then
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say("no permission to read this resource")
    return ngx.exit(ngx.OK)
end

-- storage.create: Upload data. This includes renaming files if the destination file does not already exist. This capability includes the creation of directories and subdirectories at the specified path, and the creation of any non-existent directories required to create the path itself. This authorization does not permit overwriting or deletion of stored data. The driving use case for a separate storage.create scope is to enable the stage-out of data from jobs on a worker node.
local is_create = ngx.var.request_method == "PUT" or ngx.var.request_method == "COPY" or ngx.var.request_method == "MKCOL"
-- FIXME: using read permission for testing
if string.find(res.scope, "storage.read:/") == nil and is_create then
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say("no permission to create this resource")
    return ngx.exit(ngx.OK)
end

if ngx.var.request_method == "COPY" then
    -- The COPY method is supported by ngx_http_dav_module but only for files on the same server.
    -- We intercept the method here to support third-party push copy.
    -- TODO: is this the best spot in the request lifecycle to do this?
    -- https://openresty-reference.readthedocs.io/en/latest/Directives/
    if not ngx.var.http_source then
        ngx.status = ngx.HTTP_BAD_REQUEST
        ngx.say("no source provided")
        return ngx.exit(ngx.OK)
    end

    if ngx.var.http_destination then
        ngx.status = ngx.HTTP_NOT_IMPLEMENTED
        ngx.say("third-party push copy not implemented")
        return ngx.exit(ngx.OK)
    end

    -- TODO: better way to find the local file location?
    third_party_pull(ngx.var.http_source, "/var/www" .. ngx.var.request_uri)

    -- At this point, the connection will either be safely back in the pool, or closed.
    return ngx.exit(ngx.HTTP_OK)
end

-- storage.modify: Change data. This includes renaming files, creating new files, and writing data. This permission includes overwriting or replacing stored data in addition to deleting or truncating data. This is a strict superset of storage.create.
local is_modify = ngx.var.request_method == "DELETE" or ngx.var.request_method == "MOVE"
if string.find(res.scope, "storage.read:/") == nil and is_modify then
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say("no permission to modify this resource")
    return ngx.exit(ngx.OK)
end

-- storage.stage: Read the data, potentially causing data to be staged from a nearline resource to an online resource. This is a superset of storage.read.
-- TODO: implement this