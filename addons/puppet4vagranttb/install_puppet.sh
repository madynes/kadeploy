#!/bin/sh -e
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ruby rubygems lsb-release
gem install --no-ri --no-rdoc facter
gem install --no-ri --no-rdoc puppet
