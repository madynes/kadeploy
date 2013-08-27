require 'httpd'

module Kadeploy

module Kaenv
  def envs_init_exec_context()
    ret = init_exec_context()
    ret.database = nil
    ret.client = nil
    ret.username = nil
    ret.environment = nil
    ret.show_all_version = false
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
          context.username = env['user']
        else
          context.username = context.user
        end

        unless (context.environment.load_from_desc(
          env,
          config.common.almighty_env_users,
          context.username,
          context.client
        ))
          kaerror(KadeployError::LOAD_ENV_FROM_DESC_ERROR)
        end
      end
    when :get
      parse_params(params) do |p|
        context.show_all_version = p.parse('all_versions',nil,:toggle=>true)
      end
    when :modify
      context.environment = {}
      env = context.environment
      parse_params(params) do |p|
        # Check client
        context.client = p.parse('client',String,:type=>:client)

        # Destructive toggle
        env[:destructive] = p.parse('toggle_destructive',nil,:toggle=>true)

        # Visibility modification
        env[:visibility] = p.parse('visibility',String,
          :values => ['public','private','shared'])

        # Checksums updates
        env[:update_image_checksum] = p.parse('update_image_checksum',nil,:toggle=>true)
        env[:update_preinstall_checksum] = p.parse('update_preinstall_checksum',nil,:toggle=>true)
        env[:update_postinstalls_checksum] = p.parse('update_postinstalls_checksum',nil,:toggle=>true)

        p.parse('update_files',Hash) do |files|
          env[:update_files] = {}
          files.each do |oldf,newf|
            p.check(oldf,String,:mandatory=>true)
            kaerror(APIError::INVALID_CONTENT,"Invalid file name #{newf}") \
              unless FetchFile[newf,APIError::INVALID_CONTENT,context.client]
            env[:update_files][oldf] = newf
          end
        end
      end
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
      if cexec.environment.visibility == 'public' and !config.common.almighty_env_users.include?(cexec.username)
        return [false,'Only administrators can use the "public" tag']
      end
    when :get
    when :modify
      unless config.common.almighty_env_users.include?(cexec.user)
        return [false,'Only administrators are allowed to modify other user\'s environment'] if cexec.user != user
        return [false,'Only administrators can move the files in the environments'] if cexec.environment[:update_files]
      end

      unless config.common.almighty_env_users.include?(user)
        return [false,'Only administrators can use the "public" tag'] if cexec.environment[:visibility] == 'public'
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

  def envs_modify(cexec,user=nil,name=nil,version=nil)
    fileupdate = Proc.new do |env,kind,upfile|
      file = env.send(kind.to_sym)
      next unless file
      file = file.dup

      arr = nil
      if file.is_a?(Array)
        arr = true
      else
        arr = false
        file = [file]
      end

      changes = false
      file.each do |f|
        if !upfile or (upfile and f['file'] =~ /^#{upfile[:old]}/)
          if upfile
            tmp = f['file'].gsub(upfile[:old],'')
            f['file'] = upfile[:new]
            f['file'] = File.join(f['file'],tmp) unless tmp.empty?
          end
          md5 = FetchFile[f['file'],APIError::INVALID_CONTENT,cexec.client].checksum
          kaerror(APIError::INVALID_CONTENT,"#{kind} md5") if !md5 or md5.empty?
          kaerror(APIError::NOTHING_MODIFIED) if f['md5'] and f['md5'] == md5
          f['md5'] = md5
          changes = true
        end
      end

      file = file[0] unless arr
      if changes
        EnvironmentManagement::Environment.send(
          "flatten_#{kind}".to_sym,file,true)
      else
        nil
      end
    end

    if !name and cexec.environment[:update_files]
      ret = []
      updates = {}

      envs = EnvironmentManagement::Environment.get_list_from_db(cexec.database,
        user,true,true)

      envs.each do |env|
        cexec.environment[:update_files].each do |oldf,newf|
          updates.clear

          updates['tarball'] = fileupdate.call(env,'tarball',{:old=>oldf,:new=>newf})
          updates['preinstall'] = fileupdate.call(env,'preinstall',{:old=>oldf,:new=>newf})
          updates['postinstall'] = fileupdate.call(env,'postinstall',{:old=>oldf,:new=>newf})

          updates.each{ |k,v| updates.delete(k) if v.nil? }

          unless updates.empty?
            if (r = EnvironmentManagement::Environment.update_to_db(
              cexec.database,
              name,
              version,
              user,
              true,
              updates,
              env
            )) then
              ret << r.to_hash
            else
              raise
            end
          end
        end
      end
      kaerror(APIError::NOTHING_MODIFIED) if ret.empty?
      ret
    elsif (env = EnvironmentManagement::Environment.get_from_db(
      cexec.database,
      name,
      version,
      user,
      true,
      true
    )) then
      env = env[0]
      updates = {}

      if cexec.environment[:visibility]
        updates['visibility'] = cexec.environment[:visibility]
      end

      if cexec.environment[:destructive]
        if env.demolishing_env
          updates['demolishing_env'] = 0
        else
          updates['demolishing_env'] = 1
        end
      end

      if cexec.environment[:update_image_checksum]
        updates['tarball'] = fileupdate.call(env,'tarball')
      end

      if cexec.environment[:update_preinstall_checksum]
        updates['preinstall'] = fileupdate.call(env,'preinstall')
      end

      if cexec.environment[:update_postinstalls_checksum]
        updates['postinstall'] = fileupdate.call(env,'postinstall')
      end

      updates.each{ |k,v| updates.delete(k) if v.nil? }

      if (ret = EnvironmentManagement::Environment.update_to_db(
        cexec.database,
        name,
        version,
        user,
        true,
        updates,
        env
      )) then
        ret.to_hash
      else
        kaerror(APIError::NOTHING_MODIFIED)
      end
    else
      error_not_found!
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

end
