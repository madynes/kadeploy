#!/usr/bin/ruby -w

# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'config'
require 'db'

#Ruby libs
require 'drb'

# Show the rights of a user defined in Config.exec_specific.user
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * prints the rights of a specific user
def show_rights(config, db)
  hash = Hash.new
  query = "SELECT * FROM rights WHERE user=\"#{config.exec_specific.user}\""
  res = db.run_query(query)
  if res != nil then
    res.each_hash { |row|
      if (not hash.has_key?(row["node"])) then
        hash[row["node"]] = Array.new
      end
      hash[row["node"]].push(row["part"])
    }
    if (res.num_rows > 0) then
      puts "The user #{config.exec_specific.user} has the deployment rights on the following nodes:"
      hash.each_pair { |node, part_list|
        puts "### #{node}: #{part_list.join(", ")}"
      }
    else
      puts "No rigths have been given for the user #{config.exec_specific.user}"
    end
  end
end

# Add some rights on the nodes defined in Config.exec_specific.node_list
# and on the parts defined in Config.exec_specific.part_list to a specific
# user defined in Config.exec_specific.user
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * nothing
def add_rights(config, db)
  #check if other users have rights on some nodes
  nodes_to_remove = Array.new
  config.exec_specific.node_list.each { |node|
    query = "SELECT * FROM rights WHERE user<>\"*\" AND user<>\"#{config.exec_specific.user}\" AND node=\"#{node}\""
    res = db.run_query(query)
    if (res.num_rows > 0) then
      nodes_to_remove.push(node)
    end
  }
  config.exec_specific.node_list.delete_if { |node|
    nodes_to_remove.include?(node)
  }
  if (not nodes_to_remove.empty?) then
    puts "The nodes #{nodes_to_remove.join(", ")} have been removed from the rights assignation since another user has some rights on them"
  end
  config.exec_specific.node_list.each { |node|
    config.exec_specific.part_list.each { |part|
      #check if the rights are already inserted
      query = "SELECT * FROM rights WHERE user=\"#{config.exec_specific.user}\" AND node=\"#{node}\" AND part=\"#{part}\""
      res = db.run_query(query)
      if (res.num_rows == 0) then      
        #add the rights
        query = "INSERT INTO rights (user, node, part) VALUES (\"#{config.exec_specific.user}\", \"#{node}\", \"#{part}\")"
        db.run_query(query)
      end
    }
  }
end

# Remove some rights on the nodes defined in Config.exec_specific.node_list
# and on the parts defined in Config.exec_specific.part_list to a specific
# user defined in Config.exec_specific.user
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * nothing
def delete_rights(config, db)
  config.exec_specific.node_list.each { |node|
    config.exec_specific.part_list.each { |part|
      query = "DELETE FROM rights WHERE user=\"#{config.exec_specific.user}\" AND node=\"#{node}\" AND part=\"#{part}\""
      db.run_query(query)
    }
  }
end

def _exit(exit_code, dbh)
  dbh.disconnect if (dbh != nil)
  exit(exit_code)
end

begin
  config = ConfigInformation::Config.new("karights")
rescue
  _exit(1, nil)
end
#Connect to the Kadeploy server to get the common configuration
client_config = ConfigInformation::Config.load_client_config_file
DRb.start_service()
uri = "druby://#{client_config.kadeploy_server}:#{client_config.kadeploy_server_port}"
kadeploy_server = DRbObject.new(nil, uri)
config.common = kadeploy_server.get_common_config

if (config.check_config("karights") == true)
  db = Database::DbFactory.create(config.common.db_kind)
  db.connect(config.common.deploy_db_host,
             config.common.deploy_db_login,
             config.common.deploy_db_passwd,
             config.common.deploy_db_name)

  case config.exec_specific.operation  
  when "add"
    add_rights(config, db)
  when "delete"
    delete_rights(config,db)
  when "show"
    show_rights(config, db)
  end
  _exit(0, db)
else
  puts "Invalid configuration"
  _exit(1, db)
end
