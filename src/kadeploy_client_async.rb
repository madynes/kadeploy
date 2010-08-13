#!/usr/bin/ruby -w

# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'config'
require 'error'

#Ruby libs
require 'thread'
require 'drb'
require 'socket'
require 'pp'

# Disable reverse lookup to prevent lag in case of DNS failure
Socket.do_not_reverse_lookup = true

#Connect to the server
exec_specific_config = ConfigInformation::Config.load_kadeploy_exec_specific()
if (exec_specific_config != nil) then
  DRb.start_service()
  uri = "druby://#{exec_specific_config.servers[exec_specific_config.chosen_server][0]}:#{exec_specific_config.servers[exec_specific_config.chosen_server][1]}"
  kadeploy_server = DRbObject.new(nil, uri)
  
  workflow_id = -1
  Signal.trap("INT") do
    puts "SIGINT trapped, let's clean everything ..."
    exit(1)
  end

  workflow_id, error = kadeploy_server.run("kadeploy_async", exec_specific_config, nil, nil)
  if (workflow_id != nil) then
    while (not kadeploy_server.async_deploy_ended?(workflow_id)) do
      sleep(10)
    end
    error = kadeploy_server.async_deploy_file_error?(workflow_id)
    if (error != FetchFileError::NO_ERROR) then
      puts "Error while grabbing the files (error #{error})"
    else
      pp kadeploy_server.async_deploy_get_results(workflow_id)
    end
    kadeploy_server.async_deploy_free(workflow_id)
  else
    case error
    when KadeployAsyncError::NODES_DISCARDED
      puts "All the nodes have been discarded"
    when KadeployAsyncError::NO_RIGHT_TO_DEPLOY
      puts "Invalid options or invalid rights on nodes"
    when KadeployAsyncError::UNKNOWN_NODE_IN_SINGULARITY_FILE
      puts "Unknown node in singularity file"
    when KadeployAsyncError::NODE_NOT_EXIST
      puts "At least one node in your node list does not exist"
    when KadeployAsyncError::VLAN_MGMT_DISABLED
      puts "The VLAN management has been disabled on the site"
    when KadeployAsyncError::LOAD_ENV_FROM_FILE_ERROR
      puts "The environment cannot be loaded from the file you specified"
    when KadeployAsyncError::LOAD_ENV_FROM_DB_ERROR
      puts "The environment does not exist"
    when KadeployAsyncError::NO_ENV_CHOSEN
      puts "You must choose an environment"
    end
  end

  DRb.stop_service()
  exec_specific_config = nil
  exit(0)
else
  exit(1)
end
