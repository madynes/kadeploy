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
require 'digest/sha1'
require 'md5'
require 'timeout'

class KarebootClient
  @kadeploy_server = nil
  @site = nil
  @files_ok_nodes = nil
  @files_ko_nodes = nil

  def initialize(kadeploy_server, site, files_ok_nodes, files_ko_nodes)
    @kadeploy_server = kadeploy_server
    @site = site
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
      puts "(#{@site}) #{msg}"
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
  # * cache_dir: cache directory
  # Output
  # * return true if the file has been successfully transfered, false otherwise
  def get_file(file_name, prefix, cache_dir)
    if (File.exist?(file_name)) then
      if (File.readable?(file_name)) then
        port = @kadeploy_server.create_a_socket_server(prefix + File.basename(file_name), cache_dir)
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
end

# Disable reverse lookup to prevent lag in case of DNS failure
Socket.do_not_reverse_lookup = true

exec_specific_config = ConfigInformation::Config.load_kareboot_exec_specific()
files_ok_nodes = Array.new
files_ko_nodes = Array.new

if (exec_specific_config != nil) then
  nodes_by_server = Hash.new
  remaining_nodes = exec_specific_config.node_array.clone

  if (exec_specific_config.multi_server) then
    exec_specific_config.servers.each_pair { |server,info|
      if (server != "default") then
        if (PortScanner::is_open?(info[0], info[1])) then
          distant = DRb.start_service()
          uri = "druby://#{info[0]}:#{info[1]}"
          kadeploy_server = DRbObject.new(nil, uri)
          begin
            Timeout.timeout(8) {
              nodes_known,remaining_nodes = kadeploy_server.check_known_nodes(remaining_nodes)
              if (nodes_known.length > 0) then
                nodes_by_server[server] = nodes_known
              end
            }
          rescue Timeout::Error
            puts "Cannot check the nodes on the #{server} server"
          end
          distant.stop_service()
          break if (remaining_nodes.length == 0)
        else
          puts "The #{server} server is unreachable"
        end
      end
    }
    if (not remaining_nodes.empty?) then
      puts "The nodes #{remaining_nodes.join(", ")} does not belongs to any server"
      exit(1)
    end
  else
    if (PortScanner::is_open?(exec_specific_config.servers[exec_specific_config.chosen_server][0], exec_specific_config.servers[exec_specific_config.chosen_server][1])) then
      nodes_by_server[exec_specific_config.chosen_server] = exec_specific_config.node_array
    else
      puts "The #{exec_specific_config.chosen_server} server is unreachable"
      exit(1)
    end
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
      distant = DRb.start_service()
      uri = "druby://#{exec_specific_config.servers[server][0]}:#{exec_specific_config.servers[server][1]}"
      kadeploy_server = DRbObject.new(nil, uri)

      if exec_specific_config.get_version then
        puts "(#{server}) Kareboot version: #{kadeploy_server.get_version()}"
      else
        #Launch the listener on the client
        if (exec_specific_config.multi_server) then
          kareboot_client = KarebootClient.new(kadeploy_server, server, files_ok_nodes, files_ko_nodes)
        else
          kareboot_client = KarebootClient.new(kadeploy_server, nil, files_ok_nodes, files_ko_nodes)
        end
        local = DRb.start_service(nil, kareboot_client)
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
  
        if (exec_specific_config.verbose_level != "") then
          verbose_level = exec_specific_config.verbose_level
        else
          verbose_level = nil
        end
        cloned_config = exec_specific_config.clone
        cloned_config.node_array = nodes_by_server[server]
        ret = kadeploy_server.run("kareboot_sync", cloned_config, client_host, client_port)
        local.stop_service()
        exit(ret) if ret != 0
      end
      distant.stop_service()
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
  end
  if (exec_specific_config.nodes_ko_file != "") then
    File.delete(exec_specific_config.nodes_ko_file) if File.exist?(exec_specific_config.nodes_ko_file)
    if (not files_ko_nodes.empty?) then
      files_ko_nodes.each { |file|
        system("cat #{file.path} >> #{exec_specific_config.nodes_ko_file}")
      }
    end
  end

  exit(0)
else
  exit(1)
end
