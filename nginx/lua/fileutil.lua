local sys_stat = require("posix.sys.stat")
local config = require("config")
local cksumutil = require("cksumutil")

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
---@param want_adler32 boolean
---@return {exists:boolean, is_directory:boolean, size:integer, adler32:string}
function fileutil.get_metadata(file_path, want_adler32)
    local stat = sys_stat.stat(file_path)

    if not stat then
        return {
            exists = false,
            -- If the file path ends with a slash, it will be a directory
            is_directory = file_path:sub(#file_path) == "/",
            size = 0,
            adler32 = "",
        }
    end

    -- TODO: owner, group, permissions

    local err = nil
    local adler32 = nil
    if want_adler32 then
        err, adler32 = cksumutil.get_adler32(file_path)
        if not adler32 then
            ngx.log(ngx.ERR, "Failed to get adler32 for " .. file_path .. " err: " .. err)
        end
    end

    return {
        exists = true,
        is_directory = sys_stat.S_ISDIR(stat.st_mode) ~= 0,
        size = stat.st_size,
        adler32 = adler32 or "",
    }
end

---@type function
---@param file_path string
---@param reader fun(max_chunk_size:integer): string?, string
---@param perfmarkers boolean?
---@return string? err, string? adler32
---
---Reads from the reader function and writes to the file_path.
---Returns nil if successful, otherwise an error message
---Also returns the adler32 checksum of the written data
---Set perfmarkers to send text/perf-marker-stream messages to the client.
---  (if set, this function will call ngx.say to send messages and flush them)
function fileutil.sink_to_file(file_path, reader, perfmarkers)
    local file, err = io.open(file_path, "w+b")
    if not file then
        return "failed to open file: " .. err
    end

    local buffer = nil
    local bytes_written = 0
    local last_reported = 0
    local adler_state = cksumutil.adler32_initialize()
    repeat
        buffer, err = reader(config.data.receive_buffer_size)
        if err then
            return "failed to read from the request socket: " .. err
        end
        if buffer then
            file, err = file:write(buffer)
            bytes_written = bytes_written + #buffer
            if perfmarkers and last_reported + config.data.performance_marker_threshold <= bytes_written then
                ngx.say(string.format("%d bytes written", bytes_written))
                last_reported = bytes_written
            end
            -- TODO: build checksum
            -- can use LuaJIT FFI to call C function
            -- https://stackoverflow.com/questions/53805913/how-to-define-c-functions-with-luajit
            -- e.g. a C function for https://en.wikipedia.org/wiki/Adler-32
            -- libz has this function
            cksumutil.adler32_increment(adler_state, buffer)
            if not file then
                return "failed to write to the file: " .. err
            end
        end
    until not buffer

    local adler32 = cksumutil.adler32_to_string(adler_state)
    cksumutil.set_adler32(file_path, adler32)
    file:close()

    ngx.log(ngx.NOTICE, bytes_written, " total bytes written to ", file_path, " with adler32 ", adler32)
    return nil, adler32
end

return fileutil
