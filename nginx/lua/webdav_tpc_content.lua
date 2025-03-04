local http = require("resty.http")
local config = require("config")

---@type function
---@param source_uri string
---@param destination_localpath string
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
        ngx.status = ngx.HTTP_GATEWAY_TIMEOUT
        ngx.say("connection to " .. source_uri .. " failed: " .. err)
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
        ngx.status = ngx.HTTP_BAD_GATEWAY
        ngx.say("request to path" .. path .. " failed: " .. err)
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

    repeat
        local buffer, err = reader(config.data.receive_buffer_size)
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
        ngx.status = ngx.HTTP_NOT_ALLOWED
        ngx.say("third-party push copy not implemented")
        return ngx.exit(ngx.OK)
    end

    local file_path = config.data.local_path .. ngx.var.request_uri:sub(#config.data.uriprefix + 1)
    third_party_pull(ngx.var.http_source, file_path)

    return ngx.exit(ngx.HTTP_OK)
end