local ffi = require("ffi")
local uv = require("luv")
local semaphore = require "ngx.semaphore"

-- some lua-isms added from https://github.com/user-none/lua-hashings/

local cksumutil = {}
-- Where the adler32 checksums are stored
local adler_xattr_locations = {
  "user.XrdCks.Human.ADLER32",
  "user.nginx-webdav.adler32"
}

---@type function
---@param path string
---@return string? err, string? val
---Gets the adler32 of a file, calculating it if it doesn't exist
function cksumutil.get_adler32(path)
  local err, val = cksumutil.check_adler32(path)
  if err or val == nil then
    -- We checked and didn't see an adler32, so make one
    local get_err, get_val = cksumutil.compute_adler32(path)
    if get_err then
      return get_err, nil
    end
    local set_err = cksumutil.set_adler32(path, get_val)
    if set_err then
      ngx.log(ngx.ERR, "Failed to set adler32 for " .. path .. " err: " .. set_err)
    end
    val = get_val
  end
  return nil, val
end

---@type function
---@param path string
---@param value string
---@return string? err
---Sets the adler32 of a file
function cksumutil.set_adler32(path, value)
  local total_err = nil
  for i=1,#adler_xattr_locations do
    local err = cksumutil.setxattr(path,
    adler_xattr_locations[i],
    value)
    if err then
      total_err = err
    end
  end
  return total_err
end


---@type function
---@return {a: integer, b: integer} state
---Makes a blank adler32 state
function cksumutil.adler32_initialize()
  return {a=1, b=0}
end

---@type function
---@param state {a: integer, b: integer}
---@param buf string
---@return {a: integer, b: integer} state
---increments state with the value in buf
function cksumutil.adler32_increment(state, buf)
  -- State is a = 1, b = 0 for first call
  local mod_adler = 65521
  for i=1,#buf do
    local c = string.byte(buf, i)
    state.a = (state.a + c) % mod_adler
    state.b = (state.b + state.a) % mod_adler
  end
  return state
end

---@type function
---@param state {a: integer, b: integer}
---@return string adler32
---Export adler32 state as hex string
function cksumutil.adler32_to_string(state)
  local digest = bit.bor(bit.lshift(state.b, 16), state.a)
  local bytes = {
    bit.band(bit.rshift(digest,24), 0xFF),
    bit.band(bit.rshift(digest,16), 0xFF),
    bit.band(bit.rshift(digest,8), 0xFF),
    bit.band(bit.rshift(digest,0), 0xFF),
  }
  local out = {}
  for i=1,#bytes do
    out[i] = string.format("%02X", bytes[i])
  end
  return string.lower(table.concat(out))
end

---@type function
---@param path string
---@return string? err, string val
---Given a path, compute adler32 of the file
function cksumutil.compute_adler32(path)
  -- Read 64MB blocks
  -- TODO: Make configurable
  local CHECKSUM_BLOCK_SIZE = 64 * 1024 * 1024
  local cb_complete = false
  local adler_state = cksumutil.adler32_initialize()
  local req = uv.fs_open(path, 'r', tonumber('644', 8), function(err, fd)
    -- FIXME better error handling
    assert(fd, err)

    -- Used to notify when ALL needs are done
    local more_bytes = true
    while more_bytes do
      -- Used to notify when the current read is done 
      local read_sem, err = semaphore.new()
      assert(read_sem, err)
      local read_complete = false
      uv.fs_read(fd, CHECKSUM_BLOCK_SIZE, nil, function(err, data)
        assert(not err, err)
        if (data ~= nil) and (#data ~= CHECKSUM_BLOCK_SIZE) then
          -- Short read means there was not CHECKSUM_BLOCK_SIZE 
          more_bytes = false
        end
        if data then
          -- uv.fs_read returns nil for data if EOF
          adler_state = cksumutil.adler32_increment(adler_state, data)
        end
        read_sem:post(1)
      end)
      -- This blocks until the previous read_sem.post(1) is executed
      read_sem:wait()
    end
    uv.fs_close(fd, function(err)
      if err then
        ngx.log(ngx.ERR, "Couldn't close " .. path " err: " .. err)
      end
      cb_complete = true
    end)
  end)
  while not cb_complete do
    -- I can't tell if we want "once" or "nowait", since it says once
    --
    -- "Note that this function blocks if there are no pending callbacks"
    --
    -- Does this mean it will do the I/O loop once, then block until someone
    -- triggers a callback?
    uv.run("once")
    ngx.sleep(0.000001)
  end

  return nil, cksumutil.adler32_to_string(adler_state)
end

---@type function
---@param path string
---@return string? err, string? val
---Gets the adler32 of a file from xattrs, NOT calculating if it doesn't exist
function cksumutil.check_adler32(path)
  -- xattrs to check for existing checksums
  local adler32 = nil
  for i=1,#adler_xattr_locations do
    local err, val = cksumutil.getxattr(path, adler_xattr_locations[i])
    if not err then
      return nil, val
    elseif err then
      return err, nil
    end
  end
  return nil, nil
end

-- The parts that actually call the C-level get/setxattr
-- FIXME migrate to ngx.run_worker_thread since this will block

-- Use FFI to call system-level set/getxattr calls. The FFI lib doesn't under-
-- stand void* variables, so I have to call value a const char* and not a void*
-- FIXME: Not platform-independent. Not sure how much we care
ffi.cdef[[
int setxattr(const char *path, const char *name, const char *value, size_t size,
int flags);
int getxattr(const char *path, const char *name, char *value, size_t size);
]]

---@type function
---@param path string
---@param key string
---@param value string
---@return string? err
---Sets an extended attribute on a file
function cksumutil.setxattr(path, key, value)
  local ret = ffi.C.setxattr(path, key, value, string.len(value), 0)
  if ret > 0 then
    ret = ffi.errno()
    return "Error " .. ret .. " in setxattr"
  else
    return nil
  end
end

---@type function
---@param path string
---@param key string
---@return string? err, string? value
---Gets an extended attribute from a file
function cksumutil.getxattr(path, key)
  local buflen = 1024
  local value = ffi.new("char[?]", buflen)
  local ret = ffi.C.getxattr(path, key, value, buflen)
  -- FIXME: get the C errstr
  if ret < 0 then
    ret = ffi.errno()
    -- the value doesn' exist
    local ENODATA = 63
    if ffi.errno() == ENODATA then
      -- It's not really an error if the attribute isn't there. I think nil
      -- is disctinct from "" in Lua
      return nil, nil
    else
      return "Error " .. ret .. " in getxattr", nil
    end
  else
    return nil, ffi.string(value, buflen)
  end
end

return cksumutil
