FROM openresty/openresty:centos as build

RUN yum groupinstall -y "Development Tools"
RUN /usr/local/openresty/luajit/bin/luarocks install luaposix
RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-openidc

FROM openresty/openresty:centos

COPY --from=build /usr/local/openresty/luajit /usr/local/openresty/luajit

RUN yum install -y dnsmasq

COPY conf.d/default.* /etc/nginx/conf.d/

COPY lua /etc/nginx/lua

COPY docker-entrypoint.sh /

ENTRYPOINT ["/docker-entrypoint.sh"]
