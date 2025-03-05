#!/bin/bash

# Start a dns server (just for respecting /etc/hosts)
dnsmasq -kd &
# Let nginx take over
exec nginx -g 'daemon off;'