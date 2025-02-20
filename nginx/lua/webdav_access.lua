local ngx = require "ngx"
local uv = require('luv')
local upload = require "resty.upload"

local counter = 0

local opts = {
    -- discovery = "https://cms-auth.web.cern.ch/.well-known/openid-configuration",
    -- this is the public key from the above provider
    public_key = [[-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnAO8vabKkITjjDht2dL+
GCB+zakuHsbwC6xaQWZpVePm3t9o0RO5r+fjgqux5iCPJSTr26QDvpdQ6aGmVWPz
W7oGKyEYCGwMxK8o69jIfDBkeXPQdWYAu5lWmoY3tm322o65s5luMKEexEwbzgj8
lFHxGGVK6xj3Vb0ky/bJPNOa2lV3SziD1PuiqoTUbkcI8+pUXMqhkvvVhtLjmhOW
nYRpXnJvRswePD3s0nSYwAWr7TyRm5r/UCr5MoZpWSUg3eBKw5YFiWY8EIBu70Ys
I0VY97z1mRO4S1TXwUwzr3NlB3JPmnJUKGRlh6ZceKnqGQWieS87rOn1aEUWNcxa
LwIDAQAB
-----END PUBLIC KEY-----]],
}
-- call bearer_jwt_verify for OAuth 2.0 JWT validation
local res, err = require("resty.openidc").bearer_jwt_verify(opts)

if err or not res then
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say(err and err or "no access_token provided")
    return ngx.exit(ngx.OK)
end

-- From https://github.com/WLCG-AuthZ-WG/common-jwt-profile/blob/master/profile.md#capability-based-authorization-scope

-- storage.read: Read data. Only applies to “online” resources such as disk (as opposed to “nearline” such as tape where the stage authorization should be used in addition).
local is_read = ngx.var.request_method == "GET" or ngx.var.request_method == "HEAD"
if string.find(res.scope, "storage.read:/") == nil and is_read then
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say("no permission to read this resource")
    return ngx.exit(ngx.OK)
end

-- storage.create: Upload data. This includes renaming files if the destination file does not already exist. This capability includes the creation of directories and subdirectories at the specified path, and the creation of any non-existent directories required to create the path itself. This authorization does not permit overwriting or deletion of stored data. The driving use case for a separate storage.create scope is to enable the stage-out of data from jobs on a worker node.
local is_create = ngx.var.request_method == "PUT" or ngx.var.request_method == "COPY" or ngx.var.request_method == "MKCOL"
-- FIXME: using read permission for testing
if string.find(res.scope, "storage.read:/") == nil and is_create then
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say("no permission to create this resource")
    return ngx.exit(ngx.OK)
end

-- storage.modify: Change data. This includes renaming files, creating new files, and writing data. This permission includes overwriting or replacing stored data in addition to deleting or truncating data. This is a strict superset of storage.create.
local is_modify = ngx.var.request_method == "DELETE" or ngx.var.request_method == "MOVE"
if string.find(res.scope, "storage.read:/") == nil and is_modify then
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say("no permission to modify this resource")
    return ngx.exit(ngx.OK)
end

-- storage.stage: Read the data, potentially causing data to be staged from a nearline resource to an online resource. This is a superset of storage.read.
-- TODO: implement this
