local sys_stat = require("posix.sys.stat")
local config = require("config")

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
    local file, err = io.open(file_path, "w+b")
    if not file then
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
            file, err = file:write(buffer)
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
            if not file then
                return "failed to write to the file: " .. err
            end
        end
    until not buffer

    file:close()

    ngx.log(ngx.NOTICE, bytes_written, " total bytes written to ", file_path)
end

return fileutil