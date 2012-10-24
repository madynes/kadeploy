#!/usr/bin/ruby -w

# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'config'
require 'error'

#Ruby libs
require 'thread'
require 'drb'
require 'socket'
require 'yaml'

# Disable reverse lookup to prevent lag in case of DNS failure
Socket.do_not_reverse_lookup = true

#Connect to the server
exec_specific_config = ConfigInformation::Config.load_kareboot_exec_specific()
if (exec_specific_config != nil) then
  distant = DRb.start_service()
  uri = "druby://#{exec_specific_config.servers[exec_specific_config.chosen_server][0]}:#{exec_specific_config.servers[exec_specific_config.chosen_server][1]}"
  kadeploy_server = DRbObject.new(nil, uri)
  
  Signal.trap("INT") do
    puts "SIGINT trapped, let's clean everything ..."
    exit(1)
  end

  reboot_id, error = kadeploy_server.run("kareboot_async", exec_specific_config, nil, nil)
  if (reboot_id != nil) then
    while (not kadeploy_server.async_reboot_ended?(reboot_id)) do
      sleep(10)
    end
    res = kadeploy_server.async_reboot_get_results(reboot_id)
    res['nodes_ok'] = res['nodes_ok'].keys
    res['nodes_ko'] = res['nodes_ko'].keys
    puts res.to_yaml

    kadeploy_server.async_reboot_free(reboot_id)
  end
  
  case error
  when KarebootAsyncError::REBOOT_FAILED_ON_SOME_NODES
    puts "Reboot failed on some nodes"
  when KarebootAsyncError::DEMOLISHING_ENV
    puts "Cannot reboot since the nodes have been previously deployed with a demolishinf environment"
  when KarebootAsyncError::PXE_FILE_FETCH_ERROR
    puts "Some PXE files cannot be fetched"
  when KarebootAsyncError::NO_RIGHT_TO_DEPLOY
    puts "You do not have the right to deploy on all the nodes"
  when KarebootAsyncError::UNKNOWN_NODE_IN_SINGULARITY_FILE
    puts "Unknown node in singularity file"
  when KarebootAsyncError::NODE_NOT_EXIST
    puts "At least one node in your node list does not exist"
  when KarebootAsyncError::VLAN_MGMT_DISABLED
    puts "The VLAN management has been disabled on the site"
  when KarebootAsyncError::LOAD_ENV_FROM_DB_ERROR
    puts "The environment does not exist"
  when FetchFileError::INVALID_KEY
    puts "The ssh key cannot be grabbed"
  end

  distant.stop_service()
  exec_specific_config = nil
  exit(0)
else
  exit(1)
end
