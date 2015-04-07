require 'tempfile'
require 'pathname'
require 'yaml'
require 'uri'

module Kadeploy

class Environment
  OS_KIND = [
    'linux',
    'xen',
    'other',
  ]
  IMAGE_KIND = [
    'tar',
    'dd',
    'fsa',
  ]
  IMAGE_COMPRESSION = [
    'gzip',
    'bzip2',
    'xz',
  ]

  def self.image_type_short(kind,compression)
    case kind
    when 'tar'
      case compression
      when 'gzip'
        'tgz'
      when 'bzip2'
        'tbz2'
      when 'xz'
        'txz'
      end
    when 'dd'
      case compression
      when 'gzip'
        'ddgz'
      when 'bzip2'
        'ddbz2'
      when 'xz'
        'ddxz'
      end
    when 'fsa'
      "fsa#{compression}"
    end
  end

  def self.image_type_long(type)
    case type
    when 'tgz'
      [ 'tar', 'gzip' ]
    when 'tbz2'
      [ 'tar', 'bzip2' ]
    when 'txz'
      [ 'tar', 'xz' ]
    when 'ddgz'
      [ 'dd', 'gzip' ]
    when 'ddbz2'
      [ 'dd', 'bzip2' ]
    when 'ddxz'
      [ 'dd', 'xz' ]
    when /^fsa(\d+)$/
      [ 'fsa', $1 ]
    end
  end

  YAML_SORT = [
    'name',
    'version',
    'description',
    'author',
    'visibility',
    'destructive',
    'os',
    'image',
    'preinstall',
    'postinstalls',
    'boot',
    'multipart',
    'filesystem',
    'partition_type',
    'options',
  ]
  attr_reader :id
  attr_reader :name
  attr_reader :version
  attr_reader :description
  attr_reader :author
  attr_accessor :tarball
  attr_accessor :image
  attr_accessor :preinstall
  attr_accessor :postinstall
  attr_accessor :visibility
  attr_accessor :demolishing_env
  attr_reader :kernel
  attr_reader :kernel_params
  attr_reader :initrd
  attr_reader :hypervisor
  attr_reader :hypervisor_params
  attr_reader :fdisk_type
  attr_reader :filesystem
  attr_reader :user
  attr_reader :environment_kind
  attr_reader :multipart
  attr_reader :options
  attr_reader :recorded

  def free()
    @id = nil
    @user = nil
    @name = nil
    @version = nil
    @description = nil
    @author = nil
    @visibility = nil
    @demolishing_env = nil
    @environment_kind = nil
    @tarball = nil
    @image = nil
    @preinstall = nil
    @postinstall = nil
    @kernel = nil
    @kernel_params = nil
    @initrd = nil
    @hypervisor = nil
    @hypervisor_params = nil
    @fdisk_type = nil
    @filesystem = nil
    @multipart = nil
    @options = nil
    @recorded = nil
  end

  def error(errno,msg)
    raise KadeployError.new(errno,nil,msg)
  end

  def check_os_values()
    mandatory = []
    case @image[:kind]
    when 'tar'
      case @environment_kind
      when 'xen'
        mandatory << :@hypervisor
      end
      mandatory << :@kernel
      mandatory << :@filesystem
    when 'dd'
    end

    mandatory.each do |name|
      val = self.instance_variable_get(name)
      if val.nil? or val.empty?
        return [false,"The field '#{name.to_s[1..-1]}' is mandatory for OS #{@environment_kind} with the '#{@image[:kind]}' image kind"]
      end
    end
    return [true,'']
  end

  def recorded?
    @recorded
  end

  def cache_version
    "#{@name}/#{@version}"
  end

  # Load an environment file
  #
  # Arguments
  # * description: environment description
  # * almighty_env_users: array that contains almighty users
  # * user: true user
  # Output
  # * returns true if the environment can be loaded correctly, false otherwise
  def load_from_desc(description, almighty_env_users, user, client=nil, get_checksum=true,output=nil)
    @recorded = false
    @user = user
    @preinstall = nil
    @postinstall = []
    @id = -1

    begin
      cp = Configuration::Parser.new(description)
      @name = cp.value('name',String)
      @version = cp.value('version',Fixnum,1)
      @description = cp.value('description',String,'')
      @author = cp.value('author',String,'')
      @visibility = cp.value('visibility',String,'private',['public','private','shared'])
      @demolishing_env = cp.value('destructive',[TrueClass,FalseClass],false)
      @environment_kind = cp.value('os',String,nil,OS_KIND)

      cp.parse('image',true) do
        file = cp.value('file',String)
        kind = cp.value('kind',String,nil,IMAGE_KIND)
        compress = nil
        if kind == 'fsa'
          compress = cp.value('compression',Fixnum,0,Array(0..9)).to_s
        else
          compress = cp.value('compression',String,nil,IMAGE_COMPRESSION)
        end

        md5 = nil
        if get_checksum
          md5 = FetchFile[file,client].checksum()
        else
          md5 = ''
        end
        shortkind = self.class.image_type_short(kind,compress)
        @tarball = {
          'kind' => shortkind,
          'file' => file,
          'md5' => md5,
        }
        @image = {
          :file => file,
          :kind => kind,
          :compression => compress,
          :shortkind => shortkind,
          :md5 => md5,
        }
      end

      cp.parse('preinstall') do |info|
        unless info[:empty]
          file = cp.value('archive',String)
          md5 = nil
          if get_checksum
            md5 = FetchFile[file,client].checksum()
          else
            md5 = ''
          end
          @preinstall = {
            'file' => file,
            'kind' => self.class.image_type_short(
              'tar',
              cp.value('compression',String,nil,IMAGE_COMPRESSION)
            ),
            'md5' => md5,
            'script' => cp.value('script',String,'none'),
          }
        end
      end

      cp.parse('postinstalls',false,Array) do |info|
        unless info[:empty]
          file = cp.value('archive',String)
          md5 = nil
          if get_checksum
            md5 = FetchFile[file,client].checksum()
          else
            md5 = ''
          end
          @postinstall << {
            'kind' => self.class.image_type_short(
              'tar',
              cp.value('compression',String,nil,IMAGE_COMPRESSION)
            ),
            'file' => file,
            'md5' => md5,
            'script' => cp.value('script',String,'none'),
          }
        end
      end

      @filesystem = cp.value('filesystem',String,'')
      @fdisk_type = cp.value('partition_type',Fixnum,0).to_s(16) #numeric or hexa
      @multipart = cp.value('multipart',[TrueClass,FalseClass],false)
      @options = {}
      cp.parse('options',@multipart) do |info|
        unless info[:empty]
          @options['partitions'] = []
          cp.parse('partitions',true,Array) do |info2|
            unless info2[:empty]
              tmp = {
                'id' => cp.value('id',Fixnum),
                'device' => cp.value('device',String),
              }
              # Check if 'id' already defined for another partition
              unless @options['partitions'].select{ |part|
                part['id'] == tmp['id']
              }.empty?
                raise ArgumentError.new(
                  "Partition id ##{tmp['id']} is already defined "\
                  "[field: #{info2[:path]}]"
                )
              end

              # Check if 'device' already defined for another partition
              unless @options['partitions'].select{ |part|
                part['device'] == tmp['device']
              }.empty?
                raise ArgumentError.new(
                  "Partition device '#{tmp['device']}' is already defined "\
                  "[field: #{info2[:path]}]"
                )
              end
              @options['partitions'] << tmp
            end
          end
          if !@multipart and @options['partitions'].size > 1
            warning(
              "Warning[environment description] "\
              "Multiple partitions defined with non-multipart "\
              "environment, by default, the partition #0 will be installed "\
              "on the deployment partition"
            )
          end
        end
      end

      cp.parse('boot') do
        @kernel = cp.value('kernel',String,'',Pathname)
        @initrd = cp.value('initrd',String,'',Pathname)
        @kernel_params = cp.value('kernel_params',String,'')
        @hypervisor = cp.value('hypervisor',String,'',Pathname)
        @hypervisor_params = cp.value('hypervisor_params',String,'')
        if @multipart
          @options['block_device'] = cp.value('block_device',String)
          @options['deploy_part'] = cp.value('partition',Fixnum).to_s
        end
      end


    rescue ArgumentError => ae
      error(APIError::INVALID_ENVIRONMENT,
        "Error[environment description] #{ae.message}")
    end

    cp.unused().each do |path|
      output.puts "Warning[env_desc]: Unused field '#{path}'" if output
    end

    ret = check_os_values()
    error(APIError::INVALID_ENVIRONMENT,ret[1]) unless ret[0]
    return ret[0]
  end

  # Get environment from database with context.
  #
  # Arguments
  # * dbh: database connection
  # * name: name of the requested environment if provided, nil otherwise
  # * owner_user: owner of the requested environment if provided, nil otherwise
  # * version: requested version if provided, nil otherwise
  # * context_user: name of the requester
  # * almighty_users: list of the almighty users
  # Output
  # * return a set of environments
  #
  # ======= Behavior wrt the version
  # * If version is a fixnum: return all elements with this version
  # * If version is true: the list is ordered according to the version
  # * Otherwise only the last version is returned
  #
  # ======= Behavior wrt the optional parameters
  # * If owner_user is nil or empty, look for the environments belonging to context_user first, excepted for almighty users who can see everything
  # * Private environments are returned if:
  #   * context_user is equal to owner_user or owner_user is nil
  #   * context_user is an almighty user
  # * Public environments are returned if:
  #   * owner_user is nil or empty
  #   * no environment belongs to owner_user
  def self.get_from_db_context(dbh,name,version,owner_user,context_user,almighty_users)
    is_almighty = almighty_users.include?(context_user)

    user2 = (owner_user.nil? || owner_user.empty?) && !is_almighty  ? context_user : owner_user

    get_from_db(
      dbh,
      name,
      version,
      user2,
      context_user == user2 || is_almighty,
      owner_user.nil? || owner_user.empty?
    )
  end

  def self.add_cond(args,condition,sql,value)
    if value && !value.empty?
      args<<value
      condition += sql
    end
    condition
  end

  def self.get_from_db(dbh, name, version, user, private_envs=false, public_envs=false)
    version = version.to_s if version.is_a?(Fixnum)
    args = []
    last_version = false
    sort=''
    conditions = "WHERE true "
    if name && !name.empty?
      args << name
      conditions += ' AND name like ?'
    end
    if user && !user.empty?
      args << user
      if public_envs
        conditions += " AND (user like ? OR (user <> ? AND visibility = 'public'))"
        args << user
      else
        conditions += ' AND user like ?'
      end
    end
    if !private_envs
      conditions += " AND visibility <> 'private'"
    end

    if version == true
      sort=', version desc'
    elsif version and !version.empty?
      conditions += " AND version = ?"
      args << version
    else
      last_version = true
    end

    sql = if last_version
      "select e.* from (select name,max(version) as maxversion,user "\
      "from environments #{conditions} group by name,user) m "\
      "inner join environments e on e.name = m.name and m.maxversion = e.version and m.user = e.user "\
      "ORDER BY field(visibility,'public','private','shared'), name#{sort};"
    else
      "select * from environments #{conditions} "\
      "ORDER BY field(visibility,'public','private','shared'), name#{sort};"
    end

    res = dbh.run_query(sql, *args)
    tmp = res.to_hash if res
    if tmp and !tmp.empty?
      ret = []
      tmp.each do |hash|
        ret << Environment.new.load_from_dbhash(hash)
      end
      ret
    else
      false
    end
  end

  def self.del_from_db(dbh, name, version, user, private_envs)
    # load the environment from the database (check that it exists)
    envs = get_from_db(
      dbh,
      name,
      version,
      user,
      private_envs,
      false
    )
    if envs and !envs.empty?
      env = envs[0]
      query = "DELETE FROM environments WHERE name=? AND user=?"
      args = [env.name,env.user]
      if (version and version != true and !version.empty?) or version.nil?
        query << ' AND version=?'
        args << env.version
      end
      res = dbh.run_query(query,*args)
      if res.affected_rows == 0
        return false
      else
        return envs
      end
    else
      return nil
    end
  end

  def self.update_to_db(dbh, name, version, user, private_envs, fields, env=nil)
    if fields and !fields.empty?
      # check if the fields to update exists
      tmp = Environment.new
      fields.each_key do |fieldname|
        return false unless tmp.respond_to?(fieldname.to_sym)
      end

      # load the environment from the database (check that it exists)
      if env.nil?
        env = get_from_db(
          dbh,
          name,
          version,
          user,
          private_envs,
          false
        )
        env = env[0] if env and !env.empty?
      end

      return nil unless env

      args = []
      dbfields = []
      nbtoup = 0
      fields.each_pair do |fieldname,val|
        unless env.send(fieldname.to_sym) == val
          dbfields << "#{fieldname}=?"
          args << val
          nbtoup += 1
        end
      end

      return false if nbtoup == 0

      args << env.name
      args << env.version
      args << env.user

      res = dbh.run_query(
        "UPDATE environments SET #{dbfields.join(',')} "\
        "WHERE name=? AND version=? AND user=?",
        *args
      )

      # Update the object
      fields.each_pair do |fieldname,val|
        if env.send(fieldname.to_sym) != val and env.respond_to?("#{fieldname}=".to_sym)
          case fieldname
          when 'demolishing_env'
            if val == 0
              env.demolishing_env = false
            else
              env.demolishing_env = true
            end
          when 'tarball'
            env.tarball = self.expand_tarball(val,true)
            env.image[:file] = env.tarball['file']
            env.image[:md5] = env.tarball['md5']
          when 'preinstall'
            env.preinstall = self.expand_preinstall(val,true)
          when 'postinstall'
            env.postinstall = self.expand_postinstall(val,true)
          else
            env.send("#{fieldname}=".to_sym,val)
          end
        end
      end

      if res.affected_rows == 0
        return false
      else
        return env
      end
    else
      return false
    end
  end

  def load_from_env(env)
    @id = env.id
    @user = env.user
    @name = env.name
    @version = env.version
    @description = env.description
    @author = env.author
    @visibility = env.visibility
    @demolishing_env = env.demolishing_env
    @environment_kind = env.environment_kind
    @tarball = env.tarball
    @image = env.image
    @preinstall = env.preinstall
    @postinstall = env.postinstall
    @kernel = env.kernel
    @kernel_params = env.kernel_params
    @initrd = env.initrd
    @hypervisor = env.hypervisor
    @hypervisor_params = env.hypervisor_params
    @fdisk_type = env.fdisk_type
    @filesystem = env.filesystem
    @multipart = env.multipart
    @options = env.options
    @recorded = env.recorded
    self
  end

  def load_from_db_context(dbh,name,version,user,context_user,almighty_users)
    ret =  self.class.get_from_db_context(dbh,name,version,user,context_user,almighty_users)
    #if user is not defined, own environments are selected if available
    if !ret.nil? && user.nil?
      list = ret.select { |env| env.user == context_user }
      list = ret if list.empty?
    else
      list = ret
    end
    #list should not contain more than one element when only one user is allowed to publish public environments
    load_from_env(list.first) if ret
  end

  def load_from_db(dbh, name, version, user, private_env=false, public_env=false)
    ret = self.class.get_from_db(
      dbh,
      name,
      version,
      user,
      private_env,
      public_env
    )

    if ret
      load_from_env(ret[0])
    else
      ret
    end
  end

  def load_from_dbhash(hash)
    @id = hash['id']
    @user = hash['user']
    @name = hash['name']
    @version = hash['version']
    @description = hash['description']
    @author = hash['author']
    @visibility = hash['visibility']
    @demolishing_env = (hash['demolishing_env'] == 0 ? false : true)
    @environment_kind = hash['environment_kind']
    @tarball = self.class.expand_image(hash['tarball'],true)
    tmp = self.class.image_type_long(@tarball['kind'])
    @image = {
      :file => @tarball['file'],
      :kind => tmp[0],
      :compression => tmp[1],
      :shortkind => @tarball['kind'],
      :md5 => @tarball['md5'],
    }
    @preinstall = self.class.expand_preinstall(hash['preinstall'],true)
    @postinstall = self.class.expand_postinstall(hash['postinstall'],true)
    @kernel = hash['kernel']
    @kernel_params = hash['kernel_params']
    @initrd = hash['initrd']
    @hypervisor = hash['hypervisor']
    @hypervisor_params = hash['hypervisor_params']
    @fdisk_type = hash['fdisk_type']
    @filesystem = hash['filesystem']
    @multipart = (hash['multipart'] == 0 ? false : true)
    if (!hash['options'] or hash['options'].empty?)
      @options = {}
    else
      @options = YAML.load(hash['options'])
    end
    @recorded = true
    self
  end

  # returns true if it worked, the already existing environments if it doesnt
  def save_to_db(dbh)
    if envs = self.class.get_from_db(dbh,@name,@version,@user,true,false)
      envs
    else
      dbh.run_query(
        "INSERT INTO environments (\
           name, \
           version, \
           description, \
           author, \
           tarball, \
           preinstall, \
           postinstall, \
           kernel, \
           kernel_params, \
           initrd, \
           hypervisor, \
           hypervisor_params, \
           fdisk_type, \
           filesystem, \
           user, \
           environment_kind, \
           visibility, \
           demolishing_env, \
           multipart, \
           options) \
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
         @name,
         @version,
         @description,
         @author,
         self.class.flatten_image(@tarball,true),
         self.class.flatten_preinstall(@preinstall,true),
         self.class.flatten_postinstall(@postinstall,true),
         @kernel,
         @kernel_params,
         @initrd,
         @hypervisor,
         @hypervisor_params,
         @fdisk_type,
         @filesystem,
         @user,
         @environment_kind,
         @visibility,
         (@demolishing_env ? 1 : 0),
         (@multipart ? 1 : 0),
         (@options.empty? ? '' : @options.to_yaml)
      )

      true
    end
  end

  def to_hash
    ret = {}
    ret['name'] = @name
    ret['version'] = @version
    ret['description'] = @description if !@description.nil? and !@description.empty?
    ret['author'] = @author if !@author.nil? and !@author.empty?
    ret['visibility'] = @visibility
    ret['destructive'] = @demolishing_env
    ret['os'] = @environment_kind

    ret['image'] = {}
    ret['image']['file'] = @image[:file]
    ret['image']['kind'] = @image[:kind]
    if @image[:kind] == 'fsa'
      ret['image']['compression'] = @image[:compression].to_i
    else
      ret['image']['compression'] = @image[:compression]
    end

    unless @preinstall.nil?
      ret['preinstall'] = {}
      ret['preinstall']['archive'] = @preinstall['file']
      _,ret['preinstall']['compression'] =
        self.class.image_type_long(@preinstall['kind'])
      ret['preinstall']['script'] = @preinstall['script']
    end

    if !@postinstall.nil? and !@postinstall.empty?
      ret['postinstalls'] = []
      @postinstall.each do |post|
        tmp = {}
        tmp['archive'] = post['file']
        _,tmp['compression'] =
          self.class.image_type_long(post['kind'])
        tmp['script'] = post['script']
        ret['postinstalls'] << tmp
      end
    end

    tmp = {}
    tmp['kernel'] = @kernel if !@kernel.nil? and !@kernel.empty?
    tmp['initrd'] = @initrd if !@initrd.nil? and !@initrd.empty?
    tmp['kernel_params'] = @kernel_params \
      if !@kernel_params.nil? and !@kernel_params.empty?
    tmp['hypervisor'] = @hypervisor \
      if !@hypervisor.nil? and !@hypervisor.empty?
    tmp['hypervisor_params'] = @hypervisor_params \
      if !@hypervisor_params.nil? and !@hypervisor_params.empty?
    tmp['block_device'] = @options['block_device'] \
      if !@options['block_device'].nil? and !@options['block_device'].empty?
    tmp['partition'] = @options['deploy_part'].to_i \
      if !@options['deploy_part'].nil? and !@options['deploy_part'].empty?
    ret['boot'] = tmp unless tmp.empty?

    ret['filesystem'] = @filesystem if !@filesystem.nil? and !@filesystem.empty?
    ret['partition_type'] = @fdisk_type.to_i(16)
    ret['multipart'] = @multipart
    opt = Marshal.load(Marshal.dump(@options))
    opt.delete('block_device')
    opt.delete('deploy_part')
    ret['options'] = opt unless opt.empty?

    ret
  end

  def self.flatten_image(img,md5=false)
    "#{img['file']}|#{img['kind']}#{(md5 ? '|'+img['md5'] : '')}"
  end

  def self.expand_image(img,md5=false)
    ret = {}
    tmp=img.split('|')
    ret['file'],ret['kind'] = tmp
    ret['md5'] = tmp[2] if md5
    ret
  end

  def self.flatten_preinstall(pre,md5=false)
    if !pre.nil? and !pre.empty?
      "#{pre['file']}|#{pre['kind']}#{(md5 ? '|'+pre['md5'] : '')}|#{pre['script']}"
    else
      ''
    end
  end

  def self.expand_preinstall(pre,md5=false)
    if pre.nil? or pre.empty?
      nil
    else
      ret = {}
      tmp = pre.split('|')
      ret['file'],ret['kind'] = tmp
      if md5
        ret['md5'] = tmp[2]
        ret['script'] = tmp[3]
      else
        ret['script'] = tmp[2]
      end
      ret
    end
  end

  def self.flatten_postinstall(post,md5=false)
    if !post.nil? and !post.empty?
      post.collect do |p|
        "#{p['file']}|#{p['kind']}#{(md5 ? '|'+p['md5'] : '')}|#{p['script']}"
      end.join(',')
    else
      ''
    end
  end

  def self.expand_postinstall(post,md5=false)
    if post.nil? or post.empty?
      []
    else
      ret = []
      post.split(',').each do |p|
        val = {}
        tmp = p.split('|')
        val['file'],val['kind'] = tmp
        if md5
          val['md5'] = tmp[2]
          val['script'] = tmp[3]
        else
          val['script'] = tmp[2]
        end
        ret << val
      end
      ret
    end
  end

  class << self
    alias :expand_tarball :expand_image
    alias :flatten_tarball :flatten_image
  end
end

end
