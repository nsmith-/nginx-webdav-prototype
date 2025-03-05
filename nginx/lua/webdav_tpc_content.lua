local http = require("resty.http")
local config = require("config")
local fileutil = require("fileutil")

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

    err = fileutil.sink_to_file(destination_localpath, res.body_reader, true)
    if err then
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say("failed to write to file: ", err)
        return ngx.exit(ngx.OK)
    end

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

    third_party_pull(ngx.var.http_source, fileutil.get_request_local_path())

    return ngx.exit(ngx.HTTP_OK)
end