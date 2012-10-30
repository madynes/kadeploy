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
exec_specific_config = ConfigInformation::Config.load_kadeploy_exec_specific()
if (exec_specific_config != nil) then
  distant = DRb.start_service()
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
      res = kadeploy_server.async_deploy_get_results(workflow_id)
      res['nodes_ok'] = res['nodes_ok'].keys
      res['nodes_ko'] = res['nodes_ko'].keys
      puts res.to_yaml
    end
    kadeploy_server.async_deploy_free(workflow_id)
  else
    $stderr.puts KadeployError.to_msg(error) + " (error ##{error})"
  end

  distant.stop_service()
  exec_specific_config = nil
  exit(0)
else
  exit(1)
end
