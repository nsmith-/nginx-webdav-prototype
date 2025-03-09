local ngx = require("ngx")
local fileutil = require("fileutil")


local path = fileutil.get_request_local_path()
local want_adler32 = ngx.var.http_want_digest == "adler32"
local stat = fileutil.get_metadata(path, want_adler32)
if not stat.exists then
  ngx.status = ngx.HTTP_NOT_FOUND
  ngx.exit(ngx.OK)
end

ngx.header["Content-Length"] = string.format("%d", stat.size)

if want_adler32 then
  ngx.header["Digest"] = "adler32=" .. stat.adler32
end