# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Ruby libs
require 'tempfile'
require 'pathname'
require 'yaml'

#Kadeploy libs
require 'db'
require 'md5'
require 'http'
require 'debug'
require 'configparser'

module EnvironmentManagement
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
  ]

  def self.image_type_short(kind,compression)
    case kind
    when 'tar'
      case compression
      when 'gzip'
        'tgz'
      when 'bzip2'
        'tbz2'
      end
    when 'dd'
      case compression
      when 'gzip'
        'ddgz'
      when 'bzip2'
        'ddbz2'
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
    when 'ddgz'
      [ 'dd', 'gzip' ]
    when 'ddbz2'
      [ 'dd', 'bzip2' ]
    when /^fsa(\d+)$/
      [ 'fsa', $1 ]
    end
  end

  class Environment
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
    attr_reader :kernel
    attr_reader :kernel_params
    attr_reader :initrd
    attr_reader :hypervisor
    attr_reader :hypervisor_params
    attr_reader :fdisk_type
    attr_reader :filesystem
    attr_reader :user
    attr_reader :environment_kind
    attr_reader :visibility
    attr_reader :demolishing_env
    attr_reader :multipart
    attr_reader :options
    attr_reader :recorded

    def debug(client,msg)
      Debug::distant_client_print(msg,client)
    end

    def error(client,msg)
      Debug::distant_client_error(msg,client)
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
          return [false,"The field '#{name.to_s[1..-1]}' is mandatory for OS #{@environment_kind} with the '#{type[0]}' image kind"]
        end
      end
      return [true,'']
    end

    def recorded?
      @recorded
    end

    # Load an environment file
    #
    # Arguments
    # * description: environment description
    # * almighty_env_users: array that contains almighty users
    # * user: true user
    # * client: DRb handler to client
    # * record_step: specify if the function is called for a DB record purpose
    # Output
    # * returns true if the environment can be loaded correctly, false otherwise
    def load_from_file(description, almighty_env_users, user, client, setmd5, filename=nil)
      @recorded = false
      @user = user
      @preinstall = nil
      @postinstall = []
      @id = description['id'] || -1

      filemd5 = Proc.new do |f|
        ret = nil
        if f =~ /^http[s]?:\/\//
          resp, etag = HTTP.check_file(f)
          case resp
          when 200,304
          else
            error(client,"Unable to get the file #{f} (http error ##{resp})")
          end
          ret = etag
        else
          if setmd5
            ret = client.get_file_md5(f)
            if ret == 0
              error(client,"The image file #{f} cannot be read")
              return false
            end
          end
        end
        ret
      end

      begin
        cp = ConfigInformation::ConfigParser.new(description)
        @name = cp.value('name',String)
        @version = cp.value('version',Fixnum,1)
        @description = cp.value('description',String,'')
        @author = cp.value('author',String,'')
        @visibility = cp.value('visibility',String,'private',['public','private','shared'])
        if @visibility == 'public' and !almighty_env_users.include?(@user)
          error(client,'Only the environment administrators can set the "public" tag')
          return false
        end
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
          md5 = filemd5.call(file)
          shortkind = EnvironmentManagement.image_type_short(kind,compress)
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
            @preinstall = {
              'file' => file,
              'kind' => EnvironmentManagement.image_type_short(
                'tar',
                cp.value('compression',String,nil,IMAGE_COMPRESSION)
              ),
              'md5' => filemd5.call(file),
              'script' => cp.value('script',String,'none'),
            }
          end
        end

        cp.parse('postinstalls',false,Array) do |info|
          unless info[:empty]
            file = cp.value('archive',String)
            @postinstall << {
              'kind' => EnvironmentManagement.image_type_short(
                'tar',
                cp.value('compression',String,nil,IMAGE_COMPRESSION)
              ),
              'file' => file,
              'md5' => filemd5.call(file),
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
              debug(client,
                "Warning(#{(filename ? filename : 'env_desc')}) "\
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
        debug(client,"Error(#{(filename ? filename : 'env_desc')}) #{ae.message}")
        return false
      end

      cp.unused().each do |path|
        debug(client,"Warning(#{(filename ? filename : 'env_desc')}) Unused field '#{path}'")
      end

      ret = check_os_values()
      error(client,ret[1]) unless ret[0]
      return ret[0]
    end

    def self.get_from_db(dbh, name, version, user, private_envs=false, public_envs=false)
      version = version.to_s if version.is_a?(Fixnum)

      dbproc = Proc.new do |userq,visiq|
        args = []
        query = "SELECT * FROM environments WHERE name=?"
        args << name
        if userq and !userq.empty?
          query += " AND #{userq}"
          args << user
        end
        query += " AND #{visiq}" if visiq and !visiq.empty?

        if version == true
          query += " ORDER BY version"
        elsif version and !version.empty?
          query += " AND version = ?"
          args << version
        else
          subquery = "SELECT MAX(version) FROM environments WHERE name = ?"
          args << name
          if userq and !userq.empty?
            subquery += " AND #{userq}"
            args << user
          end
          subquery += " AND #{visiq}" if visiq and !visiq.empty?
          query += " AND version = (#{subquery})"
        end

        res = dbh.run_query(query, *args)
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

      visiq = (private_envs ? nil : "visibility <> 'private'")

      # look for the environment of the specified user
      # allowing or not the check private envs
      ret = dbproc.call('user=?',visiq)

      # if no envs were found and allowed to check publics envs,
      # we check publics envs with a different user than the one specified
      if !ret and public_envs
        ret = dbproc.call('user<>?',"visibility = 'public'")
      end

      return ret
    end

    def self.del_from_db(dbh, name, version, user, private_envs)
      # load the environment from the database (check that it exists)
      env = get_from_db(
        dbh,
        name,
        version,
        user,
        private_envs,
        false
      )
      if env and !env.empty?
        env = env[0]
        res = dbh.run_query(
          "DELETE FROM environments WHERE name=? AND version=? AND user=?",
          env.name, env.version, env.user
        )
        if res.affected_rows == 0
          return false
        else
          return env
        end
      else
        return false
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

        return false unless env

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
      tmp = EnvironmentManagement.image_type_long(@tarball['kind'])
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
      @options = (!hash['options'] or hash['options'].empty? ? {} : YAML.load(hash['options']))
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

    # Print the header
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def short_view_header(client)
      out = String.new
      out += "Name                Version     User            Description\n"
      out += "####                #######     ####            ###########\n"
      Debug::distant_client_print(out, client)
    end

    # Print the short view
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def short_view(client)
      Debug::distant_client_print(sprintf("%-21s %-7s %-10s %-40s\n", @name, @version, @user, @description), client)
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
        nothing,ret['preinstall']['compression'] =
          EnvironmentManagement.image_type_long(@preinstall['kind'])
        ret['preinstall']['script'] = @preinstall['script']
      end

      if !@postinstall.nil? and !@postinstall.empty?
        ret['postinstalls'] = []
        @postinstall.each do |post|
          tmp = {}
          tmp['archive'] = post['file']
          nothing,tmp['compression'] =
            EnvironmentManagement.image_type_long(post['kind'])
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

    # Print the full view
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def full_view(client)
      # Ugly hack to write YAML attribute following a specific order
      content_hash = to_hash()
      yaml = YAML::quick_emit(content_hash) do |out|
        out.map(content_hash.taguri(), content_hash.to_yaml_style()) do |map|
          content_hash.keys.sort do |x,y|
            tmpx = YAML_SORT.index(x)
            tmpy = YAML_SORT.index(y)
            tmpx,tmpy = [x.to_s,y.to_s] if !tmpx and !tmpy
            (tmpx || max+1) <=> (tmpy || max+2)
          end.each{ |k| map.add(k, content_hash[k]) }
          #content_hash.sort_by { |k,v| k }.each{ |t| map.add(t[0],t[1]) }
          #content_hash.keys.sort.each { |k| map.add(k, content_hash[k]) }
        end
      end
      Debug::distant_client_print(yaml, client)
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

    # Set the md5 value of a file in an environment
    # Arguments
    # * kind: kind of file (tarball, preinstall or postinstall)
    # * file: filename
    # * hash: hash value
    # * dbh: database handler
    # Output
    # * return true
    def set_md5(kind, file, hash, dbh)
      return false unless @recorded
      query = ""
      case kind
      when "tarball"
        tarball = "#{@tarball["file"]}|#{@tarball["kind"]}|#{hash}"
        query = "UPDATE environments SET tarball=\"#{tarball}\""
      when "preinstall"
        preinstall = "#{@preinstall["file"]}|#{@preinstall["kind"]}|#{hash}"
        query = "UPDATE environments SET preinstall=\"#{preinstall}\""
      when "postinstall"
        postinstall_array = Array.new
        @postinstall.each { |p|
          if (file == p["file"]) then
            postinstall_array.push("#{p["file"]}|#{p["kind"]}|#{hash}|#{p["script"]}")
          else
            postinstall_array.push("#{p["file"]}|#{p["kind"]}|#{p["md5"]}|#{p["script"]}")
          end
        }
        query = "UPDATE environments SET postinstall=\"#{postinstall_array.join(",")}\""
      end
      query += " WHERE id = ?"

      dbh.run_query(query, @id)
      return true
    end

    class << self
      alias :expand_tarball :expand_image
      alias :flatten_tarball :flatten_image
    end
  end
end
