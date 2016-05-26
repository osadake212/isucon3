#!/bin/sh

redis-cli flushall
mysql isucon -u isucon < /home/isucon/webapp/ruby/init.sql
