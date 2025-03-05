local ngx = require("ngx")
local config = require("config")
local http = require("resty.http")
local fileutil = require("fileutil")

local file_path = fileutil.get_request_local_path()
local metadata = fileutil.get_metadata(file_path)

if ngx.var.request_method == "DELETE" then
    if not metadata.exists then
        ngx.status = ngx.HTTP_NOT_FOUND
        ngx.say("file not found")
        return ngx.exit(ngx.OK)
    end
    local suc, err = os.remove(file_path)
    if not suc then
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say("failed to delete file: ", err)
        return ngx.exit(ngx.OK)
    end
    ngx.status = ngx.HTTP_NO_CONTENT
    ngx.say("file deleted")
    return ngx.exit(ngx.OK)
-- TODO: implement MOVE, MKCOL?
elseif ngx.var.request_method ~= "PUT" then
    ngx.status = ngx.HTTP_NOT_ALLOWED
    ngx.say("only PUT and DELETE method is allowed to this endpoint")
    return ngx.exit(ngx.OK)
end

if metadata.is_directory then
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say("cannot write to a directory")
    return ngx.exit(ngx.OK)
end

-- After acquiring the raw socket, we cannot update the status
-- So set it to OK
ngx.status = 200

local sock, err = ngx.req.socket(true)
if not sock then
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.say("failed to get the request socket: " .. err)
    return ngx.exit(ngx.OK)
end

-- From this point on, we are in charge of sending the http response to the client
-- this is the price we pay for raw socket since the wrapped socket does not support
-- chunked body encoding

---@type function
---@param status integer
---@param message string
local function exit(status, message)
    local status_strings = {
        [200] = "OK",
        [201] = "Created",
        [204] = "No Content",
        [400] = "Bad Request",
        [500] = "Internal Server Error",
    }
    local body = message
    sock:send(string.format(
        'HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Length: %d\r\n\r\n%s',
        status, status_strings[status], #body, body
    ))
end

local reader = http.get_client_body_reader(nil, nil, sock)
if not reader then
    return exit(ngx.HTTP_INTERNAL_SERVER_ERROR, "failed to get the request body reader")
end

err = fileutil.sink_to_file(file_path, reader)
if err then
    return exit(ngx.HTTP_INTERNAL_SERVER_ERROR, err)
end

if metadata.exists then
    return exit(ngx.HTTP_NO_CONTENT, "file updated")
end

return exit(ngx.HTTP_CREATED, "file created")
