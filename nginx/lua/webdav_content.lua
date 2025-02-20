local uv = require('luv')
local ngx = require('ngx')

local function third_party_pull(source_uri, destination_localpath)
    local httpc = require("resty.http").new()

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
    end

    -- We can use the `body_reader` iterator, to stream the body according to our desired buffer size.
    local reader = res.body_reader
    local buffer_size = 16*1024*1024
    ngx.say("Beginning TPC")
    local bytes_moved = 0
    local last_marker_time = uv.now()
    repeat
        local buffer, err = reader(buffer_size)
        if err then
            ngx.log(ngx.ERR, err)
            break
        end
        if buffer then
            local current_time = uv.now()
            if (current_time - last_marker_time > 1000) then
              last_marker_time = current_time
              ngx.say("TODO - add performance markers (needed for gfal) " .. current_time)
            end
            -- TODO: build checksum
            -- can use LuaJIT FFI to call C function
            -- https://stackoverflow.com/questions/53805913/how-to-define-c-functions-with-luajit
            -- e.g. a C function for https://en.wikipedia.org/wiki/Adler-32
            -- libz has this function
            -- TODO: coroutine https://www.lua.org/manual/5.1/manual.html#2.11
            file:write(buffer)
        end
    until not buffer
    ngx.say("TPC complete")
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

local function adler32_increment(state, buf)
  -- State is a = 1, b = 0 for first call
  local mod_adler = 65521
  for s in buf:gmatch"." do
    local c = string.byte(s)
    state['a'] = (state['a'] + c) % mod_adler
    state['b'] = (state['b'] + state['a']) % mod_adler
  end
  return state
end

local function adler32_finalize(state)
  return bit.bor(bit.lshift(state['b'], 16), state['b'])
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
elseif ngx.var.request_method == "GET" then
  -- TODO handle range requests
  local fd = uv.fs_open("/var/www" .. ngx.var.request_uri, "r", 644)
  -- Amount we try to read from the filesystem at a time, most distributed
  -- filesystems have large "block sizes", so lets try a bigger number than
  -- usual
  local buffer_size = 64 * 1024 * 1024
  repeat
    -- TODO error handling
    local buffer = uv.fs_read(fd, buffer_size)
    ngx.print(buffer)
  until not buffera
  return ngx.exit(ngx.HTTP_OK)
elseif ngx.var.request_method == "PUT" then
  -- TODO write coalescing, we don't want to send a bunch of <1MB writes to a
  -- distributed filesystem
  -- TODO we don't support ranged writes (screws with checksum)
  local fd, err = uv.fs_open("/var/www" .. ngx.var.request_uri, "w", tonumber(644, 8))
  if not fd then
    ngx.say("PUT error " .. err)
    ngx.status = ngx.HTTP_NOT_IMPLEMENTED
    return ngx.exit(ngx.OK)
  end
  local sock, err = ngx.req.socket()
  -- Same justification as GET above
  local buffer_size = 64 * 1024 * 1024
  local adler_state = {a=1, b=0}
  -- TODO need to unify this with the 3rd party handler. Pass in the read fn?
  -- fns are first class citizens in lua, right?
  repeat
    -- TODO error handling
    local buffer, err = sock:receiveany(buffer_size)
    if buffer then
      adler_state = adler32_increment(adler_state, buffer) 
      uv.fs_write(fd, buffer)
    end
  until not buffer
  local adler_value = adler32_finalize(adler_state)
  ngx.say("Adler32 is " .. adler_value)
  return ngx.exit(ngx.HTTP_OK)
else
  ngx.status = ngx.HTTP_NOT_IMPLEMENTED
  ngx.say("The request " .. ngx.var.request_method .. " is not implemented")
  return ngx.exit(ngx.OK)
end


