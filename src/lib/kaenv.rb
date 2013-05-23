require 'httpd'

module Kaenv
  API_DEPLOY_PATH = '/environments'

  def envs_path(path='',prefix='')
    File.join(prefix,API_DEPLOY_PATH,path)
  end

  def envs_init_exec_context()
    ret = init_exec_context()
    ret.show_all_version = false
    ret.database = nil
    ret
  end

  def envs_prepare(params,operation)
    context = envs_init_exec_context()

    # Check database
    context.database = database_handler()

    # Check user/key
    parse_params_default(params,context)

    case operation
    when :create
      parse_params(params) do |p|
        # Check client
        context.client = p.parse('client',String,:type=>:client)

        # Check Environment
        env = p.parse('environment',Hash,:mandatory=>true)
          #:errno=>KadeployError::NO_ENV_CHOSEN)
        context.environment = EnvironmentManagement::Environment.new

        # Check user
        if env['user'] and config.common.almighty_env_users.include?(context.user)
        # almighty users can add environments for other users
          context.user = env['user']
        end

        unless (context.environment.load_from_desc(
          env,
          config.common.almighty_env_users,
          context.user,
          context.client
        ))
          kaerror(KadeployError::LOAD_ENV_FROM_DESC_ERROR)
        end
      end
    when :get
      parse_params(params) do |p|
        context.show_all_version = p.parse('all_versions',nil,:toggle=>true)
      end
      context.environment = EnvironmentManagement::Environment.new
    when :delete
    else
      raise
    end

    context
  end

  def envs_rights?(cexec,operation,user=nil,name=nil,version=nil)
    # check if env is private and cexec != user on GET
    # check if cexec == user on DELETE
    case operation
    when :create
      if cexec.environment.visibility == 'public' and !config.common.almighty_env_users.include?(cexec.user)
        return [false,'Only administrators can use the "public" tag']
      end
    when :get
    when :put
      if cexec.user != user and !config.common.almighty_env_users.include?(cexec.user)
        return [false,'Only administrators are allowed to modify other user\'s environment']
      end
    when :delete
      if cexec.user != user and !config.common.almighty_env_users.include?(cexec.user)
        return [false,'Only administrators are allowed to delete other user\'s environment']
      end
    else
      raise
    end

    return true
  end

  def envs_create(cexec)
    if (envs = cexec.environment.save_to_db(cexec.database)) == true
      cexec.environment.to_hash
    else
      if !envs.empty?
        kaerror(APIError::EXISTING_ELEMENT,
          "An environment with the name #{envs[0].name} and the version #{envs[0].version} has already been recorded for the user #{envs[0].user||''}")
      else
        kaerror(APIError::NOTHING_MODIFIED)
      end
    end
  end

  def envs_modify(cexec,user=nil,name=nil,version=nil)
  end

  def envs_get(cexec,user=nil,name=nil,version=nil)
    envs = nil
    if user and name
      if !user.empty? and !name.empty?
        envs = EnvironmentManagement::Environment.get_from_db(
          cexec.database,
          name,
          version || cexec.show_all_version,
          user,
          cexec.user == user, #If the user wants to print the environments of another user, private environments are not shown
          false
        )
      elsif user.empty? and !name.empty? # if no user and an env name, look for public envs
        envs = EnvironmentManagement::Environment.get_from_db(
          cexec.database,
          name,
          version || cexec.show_all_version,
          cexec.user,
          cexec.user == user, #If the user wants to print the environments of another user, private environments are not shown
          true
        )
      else
        error_not_found!
      end
    else
      envs = EnvironmentManagement::Environment.get_list_from_db(
        cexec.database,
        user,
        cexec.user == user, #If the user wants to print the environments of another user, private environments are not shown
        cexec.show_all_version
      )
    end

    if envs
      envs.collect do |env|
        env.to_hash.merge!({'user'=>env.user})
      end
    else
      []
    end
  end

  def envs_delete(cexec,user,name,version=nil)
    if (ret = EnvironmentManagement::Environment.del_from_db(
      cexec.database,
      name,
      version,
      user,
      true
    )) then
      ret.to_hash
    else
      kaerror(APIError::NOTHING_MODIFIED)
    end
  end
end
