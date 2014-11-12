module Kadeploy

module Kaenvs
  def envs_init_exec_context(ret)
    ret.client = nil
    ret.username = nil
    ret.environment = nil
    ret.last = false
    ret
  end

  def envs_free_exec_context(context)
    context = free_exec_context(context)
    if context.config
      context.config.free
      context.config = nil
    end
    context
  end

  def envs_prepare(params,operation,context)
    context = envs_init_exec_context(context)

    case operation
    when :create
      parse_params(params) do |p|
        # Check client
        context.client = p.parse('client',String,:type=>:client)

        # Check Environment
        env = p.parse('environment',Hash,:mandatory=>true)
        context.environment = Environment.new

        # Check user
        if env['user'] and context.almighty_users.include?(context.user)
        # almighty users can add environments for other users
          context.username = env['user']
        else
          context.username = context.user
        end

        unless (
              context.environment.load_from_desc(
                env,
                context.almighty_users,
                context.username,
                context.client
              )
            )
          kaerror(APIError::INVALID_ENVIRONMENT)
        end
      end
    when :get
      parse_params(params) do |p|
        context.last = p.parse('last',nil,:toggle=>true)
        context.env_user = p.parse('username',String)
        context.env_version = p.parse('version',String)
        context.env_name = p.parse('name',String)
      end
    when :modify
      context.config = duplicate_config()
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
            kaerror(APIError::INVALID_FILE,"Invalid file name #{newf}") \
              unless FetchFile[newf,context.client]
            env[:update_files][oldf] = newf
          end
        end

        context.last = p.parse('last',nil,:toggle=>true)
      end
    when :delete
      parse_params(params) do |p|
        context.last = p.parse('last',nil,:toggle=>true)
      end
    else
      raise
    end

    context
  end

  def envs_rights?(cexec,operation,names,user=nil,name=nil,version=nil)
    # check if env is private and cexec != user on GET
    # check if cexec == user on DELETE
    case operation
    when :create
      if cexec.environment.visibility == 'public' and !cexec.almighty_users.include?(cexec.username)
        return [false,'Only administrators can use the "public" tag']
      end
    when :get
    when :modify
      unless cexec.almighty_users.include?(cexec.user)
        return [false,'Only administrators are allowed to modify other user\'s environment'] if cexec.user != user
        return [false,'Only administrators can move the files in the environments'] if cexec.environment[:update_files]
      end

      unless cexec.almighty_users.include?(user)
        return [false,'Only administrators can use the "public" tag'] if cexec.environment[:visibility] == 'public'
      end
    when :delete
      if cexec.user != user and !cexec.almighty_users.include?(cexec.user)
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

  def envs_get(cexec)
    envs = nil
    envs = Environment.get_from_db_context(
          cexec.database,
          cexec.env_name,
          cexec.env_version || !cexec.last || nil, # if nil->last, if version->version, if true->all
          cexec.env_user,
          cexec.user,
          cexec.almighty_users
        )

    if envs
      envs.collect do |env|
        env.to_hash.merge!({'user'=>env.user})
      end
    elsif cexec.env_name or cexec.env_version
      error_not_found!
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
            FetchFile[f['file'],cexec.client].size
          else
            md5 = FetchFile[f['file'],cexec.client].checksum
            kaerror(APIError::INVALID_FILE,"#{kind} md5") if !md5 or md5.empty?
            kaerror(APIError::NOTHING_MODIFIED) if f['md5'] and f['md5'] == md5
            f['md5'] = md5
          end
          changes = true
        end
      end

      file = file[0] unless arr
      if changes
        Environment.send("flatten_#{kind}".to_sym,file,true)
      else
        nil
      end
    end

    if !name and cexec.environment[:update_files]
      ret = []
      updates = {}

      envs = Environment.get_from_db(cexec.database,user,nil,nil,true,true,true)

      envs.each do |env|
        cexec.environment[:update_files].each do |oldf,newf|
          updates.clear

          updates['tarball'] = fileupdate.call(env,'tarball',{:old=>oldf,:new=>newf})
          updates['preinstall'] = fileupdate.call(env,'preinstall',{:old=>oldf,:new=>newf})
          updates['postinstall'] = fileupdate.call(env,'postinstall',{:old=>oldf,:new=>newf})

          updates.each{ |k,v| updates.delete(k) if v.nil? }

          unless updates.empty?
            if (r = Environment.update_to_db(
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
    else
      if (!version or version.empty?) and !cexec.last
        error_not_found!
      elsif (env = Environment.get_from_db(
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

        if (ret = Environment.update_to_db(
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
          if ret.nil?
            error_not_found!
          else
            kaerror(APIError::NOTHING_MODIFIED)
          end
        end
      else
        error_not_found!
      end
    end
  end


  def envs_delete(cexec,user,name,version=nil)
    if (envs = Environment.del_from_db(
      cexec.database,
      name,
      version || !cexec.last || nil, # if nil->last, if version->version, if true->all
      user,
      true
    )) then
      envs.collect do |env|
        env.to_hash
      end
    else
      if envs.nil?
        error_not_found!
      else
        kaerror(APIError::NOTHING_MODIFIED)
      end
    end
  end
end

end
