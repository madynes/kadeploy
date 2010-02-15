#!/usr/bin/ruby -w

# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'config'

#Ruby libs
require 'thread'
require 'drb'
require 'socket'
require 'md5'
require 'tempfile'

class KadeployClient
  @kadeploy_server = nil
  @site = nil
  attr_accessor :workflow_id
  @files_ok_nodes = nil
  @files_ko_nodes = nil
  
  def initialize(kadeploy_server, site, files_ok_nodes, files_ko_nodes)
    @kadeploy_server = kadeploy_server
    @site = site
    @workflow_id = -1
    @files_ok_nodes = files_ok_nodes
    @files_ko_nodes = files_ko_nodes
  end
  
  # Print a message (RPC)
  #
  # Arguments
  # * msg: string to print
  # Output
  # * prints a message
  def print(msg)
    if (@site == nil) then
      puts msg
    else
      puts "#{@site} server: #{msg}"
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
        port = @kadeploy_server.create_a_socket_server(prefix + File.basename(file_name))
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
  # * nodes_ko: instance of NodeSet that contains the nodes not correctly deployed
  # Output
  # * nothing    
  def generate_files(nodes_ok, nodes_ko)
    t = nodes_ok.make_array_of_hostname
    if (not t.empty?) then
      file_ok = Tempfile.new("kadeploy_nodes_ok")
      @files_ok_nodes.push(file_ok)     
      t.each { |n|
        file_ok.write("#{n}\n")
      }
      file_ok.close
    end

    t = nodes_ko.make_array_of_hostname
    if (not t.empty?) then
      file_ko = Tempfile.new("kadeploy_nodes_ko")
      @files_ko_nodes.push(file_ko)      
      t.each { |n|
        file_ko.write("#{n}\n")
      }
      file_ko.close
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
    file = "#{file}_#{@site}" if (@site != nil)
    File.delete(file) if File.exist?(file)
    file = File.new(file, "w")
    file.write("#{@workflow_id}\n")
    file.close
  end
end

exec_specific_config = ConfigInformation::Config.load_kadeploy_exec_specific()

if (exec_specific_config != nil) then
  nodes_by_server = Hash.new
  remaining_nodes = exec_specific_config.node_array.clone

  if (exec_specific_config.multi_server) then
    exec_specific_config.servers.each_pair { |server,info|
      if (server != "default") then
        DRb.start_service()
        uri = "druby://#{info[0]}:#{info[1]}"
        kadeploy_server = DRbObject.new(nil, uri)
        nodes_known,remaining_nodes = kadeploy_server.check_known_nodes(remaining_nodes)
        if (nodes_known.length > 0) then
          nodes_by_server[server] = nodes_known
        end
        DRb.stop_service()
        break if (remaining_nodes.length == 0)
      end
    }
    if (not remaining_nodes.empty?) then
      puts "The nodes #{remaining_nodes.join(", ")} does not belongs to any server"
      exit(1)
    end
  else
    nodes_by_server[exec_specific_config.chosen_server] = exec_specific_config.node_array
  end
  
  tid_array = Array.new
  Signal.trap("INT") do
    puts "SIGINT trapped, let's clean everything ..."
    exit(1)
  end
  files_ok_nodes = Array.new
  files_ko_nodes = Array.new
  nodes_by_server.each_key { |server|
    tid_array << Thread.new {
      #Connect to the server
      DRb.start_service()
      uri = "druby://#{exec_specific_config.servers[server][0]}:#{exec_specific_config.servers[server][1]}"
      kadeploy_server = DRbObject.new(nil, uri)

      if exec_specific_config.get_version then
        puts "#{server} server: Kadeploy version: #{kadeploy_server.get_version()}"
      else
        if ((exec_specific_config.environment.environment_kind != "other") || (kadeploy_server.get_bootloader != "pure_pxe")) then
          #Launch the listener on the client
          if (exec_specific_config.multi_server) then
            kadeploy_client = KadeployClient.new(kadeploy_server, server, files_ok_nodes, files_ko_nodes)
          else
            kadeploy_client = KadeployClient.new(kadeploy_server, nil, files_ok_nodes, files_ko_nodes)
          end
          DRb.start_service(nil, kadeploy_client)
          if /druby:\/\/([a-zA-Z]+[-\w.]*):(\d+)/ =~ DRb.uri
            content = Regexp.last_match
            client_host = content[1]
            client_port = content[2]

            if (exec_specific_config.pxe_profile_file != "") then
              IO.readlines(exec_specific_config.pxe_profile_file).each { |l|
                exec_specific_config.pxe_profile_msg.concat(l)
              }
            end
            cloned_config = exec_specific_config.clone
            cloned_config.node_array = nodes_by_server[server]
            kadeploy_server.run("kadeploy_sync", cloned_config, client_host, client_port)
          else
            puts "#{server} server:The URI #{DRb.uri} is not correct"
          end
        else
          puts "#{server} server: only linux and xen environments can be deployed with the pure PXE configuration"
        end
      end
    }
  }
  tid_array.each { |tid|
    tid.join
  }

  #We merge the files
  if (exec_specific_config.nodes_ok_file != "") then
    File.delete(exec_specific_config.nodes_ok_file) if File.exist?(exec_specific_config.nodes_ok_file)
    if (not files_ok_nodes.empty?) then
      files_ok_nodes.each { |file|
        system("cat #{file.path} >> #{exec_specific_config.nodes_ok_file}")
      }
    end
    File.delete(exec_specific_config.nodes_ko_file) if File.exist?(exec_specific_config.nodes_ko_file)
    if (not files_ko_nodes.empty?) then
      files_ko_nodes.each { |file|
        system("cat #{file.path} >> #{exec_specific_config.nodes_ko_file}")
      }
    end
  end

  #We execute a script at the end of the deployment if required
  if (exec_specific_config.script != "") then
    system(exec_specific_config.script)
  end
  exec_specific_config = nil
  exit(0)
else
  exit(1)
end
