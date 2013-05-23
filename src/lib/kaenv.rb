require 'ostruct'
require 'json'

require 'httpd'

module Kaenv
  API_DEPLOY_PATH = '/environments'

  def envs_path(path='',prefix='')
    File.join(prefix,API_DEPLOY_PATH,path)
  end

  def envs_init_exec_context()
    ret = OpenStruct.new
    ret.user = nil
    ret.show_all_version = false
    ret.database = nil
    ret
  end

  def envs_prepare(params,operation)
    context = envs_init_exec_context()

    # Check database
    context.database = database_handler()

    if !params['user'] or !params['user'].is_a?(String) or params['user'].empty?
      kaerror(APIError::NO_USER)
    end

    # Auth user
    # TODO: authentication


    case operation
    when :create
      # Check client
      if params['client']
        begin
          context.client = URI.parse(params['client'])
          kaerror(
            APIError::INVALID_CLIENT,'Invalid client protocol'
          ) unless ['http','https'].include?(context.client.scheme.downcase)

          kaerror(
            APIError::INVALID_CLIENT,'Secure connection is mandatory for the client fileserver'
          ) if config.common.secure_client and context.client.scheme.downcase == 'http'
        rescue
          kaerror(APIError::INVALID_CLIENT,'Invalid client URI')
        end
      end

      # Check Environment
      env = params['environment']
      if !env or !env.is_a?(Hash) or env.empty?
        kaerror(KadeployError::NO_ENV_CHOSEN)
      end

      context.environment = EnvironmentManagement::Environment.new

      # Check user
      if params['environment']['user'] and config.common.almighty_env_users.include?(params['user'])
      # almighty users can add environments for other users
        context.user = params['environment']['user']
      else
        context.user = params['user']
      end

      unless (context.environment.load_from_desc(
        params['environment'],
        config.common.almighty_env_users,
        context.user,
        context.client
      ))
        kaerror(KadeployError::LOAD_ENV_FROM_DESC_ERROR)
      end
    when :get
      context.show_all_version = true if params['all_versions']
      context.user = params['user']
      context.environment = EnvironmentManagement::Environment.new
    when :delete
      context.user = params['user']
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
      if cexec.environment.visibility == 'public' and config.common.almighty_env_users.include?(cexec.user)
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
