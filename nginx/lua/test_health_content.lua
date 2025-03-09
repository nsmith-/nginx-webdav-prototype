local config = require("config")

-- A health check
local json = require('cjson')
ngx.status = ngx.HTTP_OK
if config.data["health_check_id"] and config.data["health_check_id"] ~= nil then
  ngx.say("OK " .. config.data["health_check_id"])
else
  ngx.say("OK")
end

return ngx.exit(ngx.HTTP_OK)
