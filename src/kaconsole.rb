#!/usr/bin/ruby -w

# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'config'

#Ruby libs
require 'drb'

class KaconsoleClient
  attr_reader :pid
  @killed = nil
  @pid = nil

  # Print a message (RPC)
  #
  # Arguments
  # * msg: string to print
  # Output
  # * prints a message
  def print(msg)
    puts msg
  end
  
  def connect_console(cmd)
    @killed = false
    ret_wait = 0
    @pid = fork {
      exec(cmd)
    }
    while (not @killed) 
      ret_wait = Process.waitpid(pid, Process::WNOHANG)
      @killed = true if ret_wait == @pid
      sleep(1)
    end
    if (ret_wait != @pid) then
      Process.kill("SIGKILL", @pid)
    end
  end

  def kill_console
    @killed = true
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

exec_specific_config = ConfigInformation::Config.load_kaconsole_exec_specific()

if exec_specific_config != nil then
  #Connect to the server
  distant = DRb.start_service()
  uri = "druby://#{exec_specific_config.kadeploy_server}:#{exec_specific_config.kadeploy_server_port}"
  kadeploy_server = DRbObject.new(nil, uri)

  if exec_specific_config.get_version then
    puts "Kaconsole version: #{kadeploy_server.get_version()}"
    exit(0)
  end

  kaconsole_client = KaconsoleClient.new()
  local = DRb.start_service(nil, kaconsole_client)
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

  begin
    kadeploy_server.run("kaconsole", exec_specific_config, client_host, client_port)
  rescue DRb::DRbConnError
    Process.kill("SIGKILL", kaconsole_client.pid)
    puts "Disconnection from the server, console killed"
    exit(1)
  end
  local.stop_service()
  distant.stop_service()
  exit(0)
else
  exit(1)
end
