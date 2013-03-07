#!/usr/bin/ruby -w

# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt
STATUS_UPDATE_DELAY = 2

Signal.trap("INT") do
  puts "\nSIGINT trapped, let's clean everything ..."
  exit(1)
end

#Kadeploy libs
require 'config'
require 'md5'
require 'port_scanner'

#Ruby libs
require 'thread'
require 'drb'
require 'socket'
require 'tempfile'
require 'timeout'

class KadeployClient
  @kadeploy_server = nil
  @site = nil
  attr_accessor :workflow_id
  @files_ok_nodes = nil
  @files_ko_nodes = nil
  
  def initialize(kadeploy_server, site, files_ok_nodes, files_ko_nodes)
    @kadeploy_server = kadeploy_server
    @site = site
    @workflow_id = nil
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
      msg.split("\n").each do |line|
        puts "(#{@site}) #{line}"
      end
    end
    STDOUT.flush
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
    file.write("#{(@workflow_id ? @workflow_id : -1)}\n")
    file.close
  end
end

def display_status_cluster(stat,prefix='')
  stat.each_pair do |macro,micros|
    if micros.is_a?(Hash)
      micros.each_pair do |micro,status|
        if status.is_a?(Hash)
          status[:nodes].each_pair do |state,nodes|
            unless nodes.empty?
              puts "#{prefix}  [#{macro.to_s}-#{micro.to_s}] ~#{status[:time]}s (#{state.to_s})"
              puts "#{prefix}     #{nodes.to_s_fold}"
            end
          end
        elsif status.is_a?(Nodes::NodeSet)
          puts "#{prefix}  [#{macro.to_s}-#{micro.to_s}] #{status.to_s_fold}"
        end
      end
    elsif micros.is_a?(Nodes::NodeSet)
      puts "#{prefix}  [#{macro.to_s}] #{micros.to_s_fold}"
    end
  end
end

def display_status(stats,starttime,prefix='')
  puts "#{prefix}---"
  puts "#{prefix}Nodes status (#{Time.now.to_i - starttime}s):"
  if stats.empty?
    puts "#{prefix}  Deployment done"
  elsif stats.size == 1
    if stats[stats.keys[0]].empty?
      puts "#{prefix}  Deployment did not start at the moment"
    else
      display_status_cluster(stats[stats.keys[0]],prefix)
    end
  else
    stats.each_pair do |clname,stat|
      puts "#{prefix}  [#{clname}]"
      if stat.empty?
        puts "#{prefix}    Deployment did not start at the moment"
      else
        display_status_cluster(stat,"#{prefix}  ")
      end
    end
  end
  puts "#{prefix}---"
end

# Disable reverse lookup to prevent lag in case of DNS failure
Socket.do_not_reverse_lookup =true

exec_specific_config = ConfigInformation::Config.load_kadeploy_exec_specific()

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
        else
          puts "The #{server} server is unreachable"
        end
        break if (remaining_nodes.length == 0)
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
  
  threads = []

  files_ok_nodes = Array.new
  files_ko_nodes = Array.new

  remoteobjects = []

  nodes_by_server.each_key { |server|
    threads << Thread.new {
      begin
        #Connect to the server
        Thread.current[:server] = exec_specific_config.servers[server]
        distant = DRb.start_service()
        uri = "druby://#{exec_specific_config.servers[server][0]}:#{exec_specific_config.servers[server][1]}"
        kadeploy_server = DRbObject.new(nil, uri)

        if exec_specific_config.get_version then
          puts "(#{server}) Kadeploy version: #{kadeploy_server.get_version()}"
        else
          #Launch the listener on the client
          if (exec_specific_config.multi_server) then
            kadeploy_client = KadeployClient.new(kadeploy_server, server, files_ok_nodes, files_ko_nodes)
          else
            kadeploy_client = KadeployClient.new(kadeploy_server, nil, files_ok_nodes, files_ko_nodes)
          end
          local = DRb.start_service(nil, kadeploy_client)        
          if /druby:\/\/([a-zA-Z]+[-\w.]*):(\d+)/ =~ local.uri
            remoteobjects << {
              :server => kadeploy_server,
              :client => kadeploy_client,
              :name => server,
            }
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
            cloned_config = exec_specific_config.clone
            cloned_config.node_array = nodes_by_server[server]


            kadeploy_server.run("kadeploy_sync", cloned_config, client_host, client_port)
          else
            puts "(#{server}) The URI #{local.uri} is not correct"
          end
          wid = kadeploy_client.workflow_id
          if wid
            kadeploy_server.kasync(wid){ local.stop_service() }
            kadeploy_server.delete_kasync(wid)
          end
        end
        distant.stop_service()
      rescue DRb::DRbConnError => dce
        puts "[ERROR] Server disconnection: #{dce.message} (#{exec_specific_config.servers[server][0]}:#{exec_specific_config.servers[server][1]})"
        puts "---- Stack trace ----"
        puts dce.backtrace
        puts "---------------------"
      end
    }
  }

  starttime = Time.now.to_i

  if STDIN.tty? and !STDIN.closed?
    status_thr = Thread.new do
      last_status = Time.now
      while true
        STDIN.gets
        if Time.now - last_status > STATUS_UPDATE_DELAY
          prefix = (remoteobjects.size > 1)
          remoteobjects.each do |obj|
            display_status(
              obj[:server].async_deploy_get_status(obj[:client].workflow_id),
              starttime,
              (prefix ? "[#{obj[:name]}] " : '')
            )
          end
          last_status = Time.now
        end
      end
    end
  end

  threads.each do |thr|
    begin
      thr.join
    rescue SystemExit
    rescue Exception => e
      server = "(#{thr[:server][0]}:#{thr[:server][1]})" if thr and thr[:server]
      puts "[ERROR] Server disconnection: an exception was raised #{server}"
      puts "---- #{e.class.name} ----"
      puts e.message
      puts "---- Stack trace ----"
      puts e.backtrace
      puts "---------------------"
      next
    end
  end

  if STDIN.tty? and !STDIN.closed?
    status_thr.kill
    status_thr.join
  end

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

  #We execute a script at the end of the deployment if required
  if (exec_specific_config.script != "") then
    system(exec_specific_config.script)
  end

  exec_specific_config = nil
  exit(0)
else
  exit(1)
end
