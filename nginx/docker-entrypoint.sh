#!/bin/bash -e

dnsmasq -kd &
nginx -g 'daemon off;'