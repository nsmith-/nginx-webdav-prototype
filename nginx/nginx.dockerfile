FROM openresty/openresty:centos

RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-openidc

RUN yum install -y dnsmasq

COPY docker-entrypoint.sh /

ENTRYPOINT [ "bash" ]
CMD [ "/docker-entrypoint.sh" ]