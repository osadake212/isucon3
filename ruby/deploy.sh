#!/bin/sh

set -e

cd $(dirname $0)
bundle check || bundle install --without development
sudo supervisorctl restart isucon_ruby
