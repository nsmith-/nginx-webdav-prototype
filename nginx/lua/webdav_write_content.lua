local ngx = require("ngx")
local config = require("config")
local sys_stat = require("posix.sys.stat")

local file_path = config.data.local_path .. ngx.var.request_uri:sub(#config.data.uriprefix + 1)
local stat = sys_stat.stat(file_path)
local is_directory = (stat and sys_stat.S_ISDIR(stat.st_mode) ~= 0) or (file_path:sub(#file_path) == "/")
local file_existed = stat ~= nil

if ngx.var.request_method == "DELETE" then
    if not file_existed then
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

if is_directory then
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say("cannot write to a directory")
    return ngx.exit(ngx.OK)
end

local reader, err = ngx.req.socket()
if not reader then
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.say("failed to get the request socket: " .. err)
    return ngx.exit(ngx.OK)
end

local file = nil
file, err = io.open(file_path, "w")
if file == nil then
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.say("failed to open file: " .. err)
    return ngx.exit(ngx.OK)
end

local buffer = nil
repeat
    buffer, err = reader:receiveany(config.data.receive_buffer_size)
    local closed = err ~= nil and err:sub(1, 6) == "closed"
    if err and not closed then
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.say("failed to read from the request socket: " .. err)
        return ngx.exit(ngx.OK)
    end
    if buffer then
        file:write(buffer)
    end
    if closed then
        break
    end
until not buffer

file:close()

if file_existed then
    ngx.status = ngx.HTTP_NO_CONTENT
    ngx.say("file updated")
    return ngx.exit(ngx.status)
end

ngx.status = ngx.HTTP_CREATED
ngx.say("file created")
return ngx.exit(ngx.status)