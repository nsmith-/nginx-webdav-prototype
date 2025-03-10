# This is intended for use when bind-mounting nginx/conf.d and nginx/lua
# to the container. It installs the necessary dependencies for the lua
# modules to work.
FROM openresty/openresty:centos

RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-openidc

RUN yum groupinstall -y "Development Tools"
RUN /usr/local/openresty/luajit/bin/luarocks install luaposix

RUN yum install -y dnsmasq

COPY docker-entrypoint.sh /

ENTRYPOINT ["/docker-entrypoint.sh"]
