FROM openresty/openresty:centos

RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-openidc

RUN yum groupinstall -y "Development Tools"
RUN /usr/local/openresty/luajit/bin/luarocks install luaposix

RUN yum install -y dnsmasq

COPY docker-entrypoint.sh /

ENTRYPOINT ["/docker-entrypoint.sh"]