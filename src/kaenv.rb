#!/usr/bin/ruby -w

# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'config'
require 'md5'
require 'port_scanner'

#Ruby libs
require 'drb'


class KaenvClient
  # Print a message (RPC)
  #
  # Arguments
  # * msg: string to print
  # Output
  # * prints a message
  def print(msg)
    puts msg
  end

  # Get the MD5 of a file from the client (RPC)
  #
  # Arguments
  # * file_name: name of the file on the client side
  # Output
  # * return the MD5 of the file, or 0 if it cannot be read.
  def get_file_md5(file_name)
    if File.readable?(file_name) then
      return MD5::get_md5_sum(file_name)
    else
      return 0
    end
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

exec_specific_config = ConfigInformation::Config.load_kaenv_exec_specific()

if exec_specific_config != nil then
  if not (PortScanner::is_open?(exec_specific_config.kadeploy_server, exec_specific_config.kadeploy_server_port)) then
    puts "The server #{exec_specific_config.chosen_server} is unreahchable"
    exit(1)
  end
  #Connect to the server
  distant = DRb.start_service()
  uri = "druby://#{exec_specific_config.kadeploy_server}:#{exec_specific_config.kadeploy_server_port}"
  kadeploy_server = DRbObject.new(nil, uri)

  if exec_specific_config.get_version then
    puts "Kaenv version: #{kadeploy_server.get_version()}"
    exit(0)
  end

  kaenv_client = KaenvClient.new()
  local = DRb.start_service(nil, kaenv_client)
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

  ret = kadeploy_server.run("kaenv", exec_specific_config, client_host, client_port)
  local.stop_service()
  distant.stop_service()
  exit(ret)
else
  exit(1)
end
