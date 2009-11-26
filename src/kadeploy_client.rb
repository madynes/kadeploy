#!/usr/bin/ruby -w

# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'config'

#Ruby libs
require 'thread'
require 'drb'
require 'socket'
require 'md5'

class KadeployClient
  @kadeploy_server = nil
  attr_accessor :workflow_id
  
  def initialize(kadeploy_server)
    @kadeploy_server = kadeploy_server
    @workflow_id = -1
  end
  
  # Print a message (RPC)
  #
  # Arguments
  # * msg: string to print
  # Output
  # * prints a message
  def print(msg)
    puts msg
  end

  # Stop the DRB service and to release the client (RPC)
  #
  # Arguments
  # * nothing
  # Output
  # * nothing
  def exit
    DRb.stop_service()
  end

  # Test method to check that the client is still there (RPC)
  #
  # Arguments
  # * nothing
  # Output
  # * nothing
  def test
  end

  # Get a file from the client (RPC)
  #
  # Arguments
  # * file_name: name of the file on the client side
  # * prefix: prefix to add to the file_name
  # Output
  # * return true if the file has been successfully transfered, false otherwise
  def get_file(file_name, prefix)
    if (File.exist?(file_name)) then
      if (File.readable?(file_name)) then
        port = @kadeploy_server.kadeploy_sync_create_a_socket_server(prefix + File.basename(file_name))
        if port != -1 then
          sock = TCPSocket.new(@kadeploy_server.dest_host, port)
          file = File.open(file_name)
          tcp_buffer_size = @kadeploy_server.tcp_buffer_size
          while (buf = file.read(tcp_buffer_size))
            sock.send(buf, 0)
          end
          sock.close
          return true
        else
          return false
        end
      else
        puts "The file #{file_name} cannot be read"
        return false
      end
    else
      puts "The file #{file_name} cannot be found"
      return false
    end
  end
  
  # Get the mtime of a file from the client (RPC)
  #
  # Arguments
  # * file_name: name of the file on the client side
  # Output
  # * return the mtime of the file, or 0 if it cannot be read.
  def get_file_mtime(file_name)
    if File.readable?(file_name) then
      return File.mtime(file_name).to_i
    else
      return 0
    end
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

  # Get the size of a file from the client (RPC)
  #
  # Arguments
  # * file_name: name of the file on the client side
  # Output
  # * return the size of the file, or 0 if it cannot be read.
  def get_file_size(file_name)
    if File.readable?(file_name) then
      return File.stat(file_name).size
    else
      return 0
    end
  end

  # Print the results of the deployment (RPC)
  #
  # Arguments
  # * nodes_ok: instance of NodeSet that contains the nodes correctly deployed
  # * file_ok: destination filename to store the nodes correctly deployed
  # * nodes_ko: instance of NodeSet that contains the nodes not correctly deployed
  # * file_ko: destination filename to store the nodes not correctly deployed
  # Output
  # * nothing    
  def generate_files(nodes_ok, file_ok, nodes_ko, file_ko)
    if (file_ok != "") then
      File.delete(file_ok) if File.exist?(file_ok)
      t = nodes_ok.make_array_of_hostname
      if (not t.empty?) then
        file = File.new(file_ok, "w")
        t.each { |n|
          file.write("#{n}\n")
        }
        file.close
      end
    end
    if (file_ko != "") then
      File.delete(file_ko) if File.exist?(file_ko)
      t = nodes_ko.make_array_of_hostname
      if (not t.empty?) then
        file = File.new(file_ko, "w")
        t.each { |n|
          file.write("#{n}\n")
        }
        file.close
      end
    end
  end
  
  # Set the workflow id (RPC)
  #
  # Arguments
  # * id: id of the workflow
  # Output
  # * nothing
  def set_workflow_id(id)
    @workflow_id = id
  end

  # Write the workflow id in a file (RPC)
  #
  # Arguments
  # * file: destination file
  # Output
  # * nothing
  def write_workflow_id(file)
    File.delete(file) if File.exist?(file)
    file = File.new(file, "w")
    file.write("#{@workflow_id}\n")
    file.close
  end
end

exec_specific_config = ConfigInformation::Config.load_kadeploy_exec_specific()

if (exec_specific_config != nil) then
  #Connect to the server
  DRb.start_service()
  uri = "druby://#{exec_specific_config.kadeploy_server}:#{exec_specific_config.kadeploy_server_port}"
  kadeploy_server = DRbObject.new(nil, uri)

  if exec_specific_config.get_version then
    puts "Kadeploy version: #{kadeploy_server.get_version()}"
    exit(0)
  end

  if ((exec_specific_config.environment.environment_kind != "other") || (kadeploy_server.get_bootloader != "pure_pxe")) then

    #Launch the listener on the client
    kadeploy_client = KadeployClient.new(kadeploy_server)
    DRb.start_service(nil, kadeploy_client)
    if /druby:\/\/([a-zA-Z]+[-\w.]*):(\d+)/ =~ DRb.uri
      content = Regexp.last_match
      client_host = content[1]
      client_port = content[2]
    else
      puts "The URI #{DRb.uri} is not correct"
      exit(1)
    end
    Signal.trap("INT") do
      puts "SIGINT trapped, let's clean everything ..."
      kadeploy_server.kadeploy_sync_kill_workflow(kadeploy_client.workflow_id)
      exit(1)
    end
    if (exec_specific_config.pxe_profile_file != "") then
      IO.readlines(exec_specific_config.pxe_profile_file).each { |l|
        exec_specific_config.pxe_profile_msg.concat(l)
      }
    end
    kadeploy_server.run("kadeploy_sync", exec_specific_config, client_host, client_port)
    #We execute a script at the end of the deployment if required
    if (exec_specific_config.script != "") then
      system(exec_specific_config.script)
    end
    exec_specific_config = nil
    exit(0)
  else
    puts "Only linux and xen environments can be deployed with the pure PXE configuration"
    exit(1)
  end
  exit(0)
else
  exit(1)
end
