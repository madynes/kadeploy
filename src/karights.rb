#!/usr/bin/ruby -w

# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'config'
require 'port_scanner'

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

  # Test method to check that the client is still there (RPC)
  #
  # Arguments
  # * nothing
  # Output
  # * nothing
  def test
  end
end

# Disable reverse lookup to prevent lag in case of DNS failure
Socket.do_not_reverse_lookup = true

exec_specific_config = ConfigInformation::Config.load_karights_exec_specific()

if (exec_specific_config != nil) then
  unless PortScanner::is_open?(exec_specific_config.kadeploy_server, exec_specific_config.kadeploy_server_port)
    puts "The server #{exec_specific_config.chosen_server} is unreahchable"
    exit(1)
  end
  #Connect to the server
  distant = DRb.start_service()
  uri = "druby://#{exec_specific_config.kadeploy_server}:#{exec_specific_config.kadeploy_server_port}"
  kadeploy_server = DRbObject.new(nil, uri)

  if exec_specific_config.get_version then
    puts "Karights version: #{kadeploy_server.get_version()}"
    exit(0)
  end

  karights_client = KarightsClient.new()
  local = DRb.start_service(nil, karights_client)
  if /druby:\/\/([a-zA-Z]+[-\w.]*):(\d+)/ =~ local.uri
    content = Regexp.last_match
    hostname = Socket.gethostname
    client_host = String.new
    if hostname.include?(client_host) then
      #It' best to get the FQDN
      client_host = hostname
    else
      client_host = content[1]
    end
    client_port = content[2]
  else
    puts "The URI #{local.uri} is not correct"
    exit(1)
  end
  res = kadeploy_server.run("karights", exec_specific_config, client_host, client_port)
  local.stop_service()
  distant.stop_service()
  exit((res)?0:1)
else
  exit(1)
end
