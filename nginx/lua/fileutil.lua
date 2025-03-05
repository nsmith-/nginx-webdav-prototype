local sys_stat = require("posix.sys.stat")
local config = require("config")
local uv = require("luv")

local fileutil = {}

---@type function
---@return string
function fileutil.get_request_local_path()
    local uri = ngx.var.request_uri
    -- TODO: can we find the local path from ngx.var variables?
    return config.data.local_path .. uri:sub(#config.data.uriprefix + 1)
end

---@type function
---@param file_path string
---@return {exists:boolean, is_directory:boolean}
function fileutil.get_metadata(file_path)
    local stat = sys_stat.stat(file_path)

    if not stat then
        return {
            exists = false,
            -- If the file path ends with a slash, it will be a directory
            is_directory = file_path:sub(#file_path) == "/",
        }
    end

    -- TODO: owner, group, permissions
    -- TODO: xattr

    return {
        exists = true,
        is_directory = sys_stat.S_ISDIR(stat.st_mode) ~= 0,
    }
end

---@type function
---@param file_path string
---@param reader fun(max_chunk_size:integer): string?, string
---@param perfcounter boolean?
---@return string?
---
---Reads from the reader function and writes to the file_path.
---Returns nil if successful, otherwise an error message.
---Set perfcounter to report every so often the number of bytes written.
function fileutil.sink_to_file(file_path, reader, perfcounter)
    local fd = nil
    local err = nil
    uv.fs_open(file_path, "w", tonumber('644', 8), function(_err, _fd)
        err = _err
        fd = _fd
    end)
    while not (fd or err) do
        uv.run("once")
        ngx.sleep(0)
    end
    if not fd then
        return "failed to open file: " .. err
    end

    local buffer = nil
    local bytes_written = 0
    local last_reported = 0
    repeat
        buffer, err = reader(config.data.receive_buffer_size)
        if err then
            return "failed to read from the request socket: " .. err
        end
        if buffer then
            local nbytes = nil
            uv.fs_write(fd, buffer, function(_err, _nbytes)
                err = _err
                nbytes = _nbytes
            end)
            while not (nbytes or err) do
                uv.run("once")
                ngx.sleep(0)
            end
            if not nbytes then
                return "failed to write to the file: " .. err
            end
            if nbytes ~= #buffer then
                return "failed to write all bytes to the file"
            end
            bytes_written = bytes_written + #buffer
            if perfcounter and last_reported + config.data.performance_marker_threshold <= bytes_written then
                ngx.say(string.format("%d bytes written", bytes_written))
                last_reported = bytes_written
            end
            -- TODO: build checksum
            -- can use LuaJIT FFI to call C function
            -- https://stackoverflow.com/questions/53805913/how-to-define-c-functions-with-luajit
            -- e.g. a C function for https://en.wikipedia.org/wiki/Adler-32
            -- libz has this function
        end
    until not buffer

    local success = nil
    uv.fs_close(fd, function(_err, _success)
        err = _err
        success = _success
    end)
    while not (success or err) do
        uv.run("once")
        ngx.sleep(0)
    end
    if not success then
        return "failed to close the file: " .. err
    end

    ngx.log(ngx.NOTICE, bytes_written, " total bytes written to ", file_path)
end

return fileutil