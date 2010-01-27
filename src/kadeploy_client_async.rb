#!/usr/bin/ruby -w

# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'checkrights'
require 'config'
require 'db'

#Ruby libs
require 'thread'
require 'drb'
require 'socket'


def _exit(exit_code, dbh)
  dbh.disconnect if (dbh != nil)
  exit(exit_code)
end


client_config = ConfigInformation::Config.load_client_config_file

#Connect to the server
DRb.start_service()
uri = "druby://#{client_config.kadeploy_server}:#{client_config.kadeploy_server_port}"
kadeploy_server = DRbObject.new(nil, uri)
common_config = kadeploy_server.get_common_config

#Connect to the database
db = Database::DbFactory.create(common_config.db_kind)
db.connect(common_config.deploy_db_host,
           common_config.deploy_db_login,
           common_config.deploy_db_passwd,
           common_config.deploy_db_name)

exec_specific_config = ConfigInformation::Config.load_kadeploy_exec_specific(common_config, db)
if (exec_specific_config != nil) then
  if ((exec_specific_config.environment.environment_kind != "other") || (common_config.bootloader != "pure_pxe")) then
    #Rights check
    allowed_to_deploy = true
    #The rights must be checked for each cluster if the node_list contains nodes from several clusters
    exec_specific_config.node_list.group_by_cluster.each_pair { |cluster, set|
      if (exec_specific_config.deploy_part != "") then
        if (exec_specific_config.block_device != "") then
          part = exec_specific_config.block_device + exec_specific_config.deploy_part
        else
          part = kadeploy_server.get_block_device(cluster) + exec_specific_config.deploy_part
        end
      else
        part = kadeploy_server.get_default_deploy_part(cluster)
      end
      allowed_to_deploy = CheckRights::CheckRightsFactory.create(common_config.rights_kind,
                                                                 set,
                                                                 db,
                                                                 part).granted?
    }
    if (allowed_to_deploy == true) then
      workflow_id = -1
      Signal.trap("INT") do
        puts "SIGINT trapped, let's clean everything ..."
        kadeploy_server.kill_workflow(workflow_id)
        _exit(1, db)
      end
      if (exec_specific_config.pxe_profile_file != "") then
        IO.readlines(exec_specific_config.pxe_profile_file).each { |l|
          exec_specific_config.pxe_profile_msg.concat(l)
        }
      end
      workflow_id, error = kadeploy_server.launch_workflow_async(exec_specific_config)
      
      if (workflow_id != nil) then
        while (not kadeploy_server.ended?(workflow_id)) do
          sleep(10)        
        end
        puts kadeploy_server.get_results(workflow_id)
        kadeploy_server.free(workflow_id)
      else
        case error
        when 1
          puts "All the nodes have been discarded"
        when 2
          puts "Some files cannot be grabbed"
        end
      end
      exec_specific_config = nil
    else
      puts "You do not have the deployment rights on all the nodes"
      _exit(1, db)
    end
  else
    puts "Only linux and xen environments can be deployed with the pure PXE configuration"
    _exit(1, db)
  end
  _exit(0, db)
else
  _exit(1, db)
end
