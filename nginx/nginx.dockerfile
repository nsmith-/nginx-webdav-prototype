FROM openresty/openresty:centos

RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-openidc

RUN yum groupinstall -y "Development Tools"
RUN /usr/local/openresty/luajit/bin/luarocks install luaposix

RUN yum install -y cmake
RUN curl -fL https://github.com/truemedian/luvit-bin/raw/main/install.sh | sh
RUN /usr/local/openresty/luajit/bin/luarocks install luv

RUN yum install -y dnsmasq

COPY docker-entrypoint.sh /

ENTRYPOINT ["/docker-entrypoint.sh"]