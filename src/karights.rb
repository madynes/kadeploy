#!/usr/bin/ruby -w

# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'config'

#Ruby libs
require 'drb'

class KarightsClient
  # Print a message (RPC)
  #
  # Arguments
  # * msg: string to print
  # Output
  # * prints a message
  def print(msg)
    puts msg
  end
end

# Disable reverse lookup to prevent lag in case of DNS failure
Socket.do_not_reverse_lookup = true

exec_specific_config = ConfigInformation::Config.load_karights_exec_specific()

if (exec_specific_config != nil) then
  #Connect to the server
  DRb.start_service()
  uri = "druby://#{exec_specific_config.kadeploy_server}:#{exec_specific_config.kadeploy_server_port}"
  kadeploy_server = DRbObject.new(nil, uri)

  if exec_specific_config.get_version then
    puts "Karights version: #{kadeploy_server.get_version()}"
    exit(0)
  end

  karights_client = KarightsClient.new()
  DRb.start_service(nil, karights_client)
  if /druby:\/\/([a-zA-Z]+[-\w.]*):(\d+)/ =~ DRb.uri
    content = Regexp.last_match
    client_host = content[1]
    client_port = content[2]
  else
    puts "The URI #{DRb.uri} is not correct"
    exit(1)
  end

  kadeploy_server.run("karights", exec_specific_config, client_host, client_port)

  exit(0)
else
  exit(1)
end
