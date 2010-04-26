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
    if (kadeploy_server.async_deploy_file_error?(workflow_id) != 0) then
      puts "Error while grabbing the files"
    else
      puts kadeploy_server.async_deploy_get_results(workflow_id)
    end
    kadeploy_server.async_deploy_free(workflow_id)
  else
    case error
    when 1
      puts "All the nodes have been discarded"
    when 2
      puts "Invalid options or invalid rights on nodes"
    end
  end

  DRb.stop_service()
  exec_specific_config = nil
  exit(0)
else
  exit(1)
end
