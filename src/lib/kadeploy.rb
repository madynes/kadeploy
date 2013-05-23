module Kadeploy
  API_DEPLOY_PATH = '/deploy'

  def deploy_path(path='',prefix='')
    File.join(prefix,API_DEPLOY_PATH,path)
  end

  def deploy_check_params(params)
    options = {}

    # Check nodelist
    if !params['nodes'] or !params['nodes'].is_a?(Array) or params['nodes'].empty?
      kaerror(APIError::INVALID_NODELIST)
    end

    # Check nodes
    #params['nodes'].each do |hostname|
    #  if not add_to_node_set(hostname, exec_specific_config) then
    #    Debug::distant_client_error("The node #{hostname} does not exist", client)
    #    return KadeployAsyncError::NODE_NOT_EXIST
    #  end
    #}
    #options[:nodelist] = params['nodes']

    options
  end

  def deploy_run(options)
    info = {
      :wid => uuid('D-'),
      :start_time => Time.now,
      :done => false,
      :nodelist => options[:nodelist],
      :nodes => {}, # Hash, one key per node + current status
      :workflows => [],
    }

    info[:thread] = Thread.new do
      wid = info[:wid].dup
      sleep 3
    end

    create_workflow(:deploy,info[:wid],info)

    info[:wid]
  end

  def deploy_get(wid)
    get_workflow(:deploy,wid) do |info|
      done = nil
      if info[:thread].alive?
        done = false
      else
        info[:thread].join
        done = true
        info[:done] = true
      end
      {
        :nodelist => info[:nodelist],
        :time => (Time.now - info[:start_time]).round(2),
        :done => done,
      }
    end
  end

  def deploy_delete(wid)
    delete_workflow(:deploy,wid) do |info|
      info[:thread].kill if info[:thread].alive?
      info[:workflows].each do |workflow|
        workflow.kill
        workflow.free
      end
      GC.start
      { :wid => wid }
    end
  end
end
