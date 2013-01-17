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
      'filesystem',
      'partition_type',
    ]
    attr_reader :id
    attr_reader :name
    attr_reader :version
    attr_reader :description
    attr_reader :author
    attr_accessor :tarball
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

    def error(client,msg)
      Debug::distant_client_error(msg,client)
    end

    def check_os_values()
      mandatory = []
      type = EnvironmentManagement.image_type_long(@tarball['kind'])
      case type[0]
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
    def load_from_file(description, almighty_env_users, user, client, record_in_db, filename=nil)
      @user = user
      @preinstall = nil
      @postinstall = []
      @id = -1

      filemd5 = Proc.new do |f|
        ret = nil
        if f =~ /^http[s]?:\/\//
          ret = ''
        else
          if record_in_db
            ret = client.get_file_md5(f)
            if ret == 0
              error(client,"The tarball file #{f} cannot be read")
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
        @visibility = cp.value('visibility',String,'shared',['public','private','shared'])
        if @visibility == 'public' and !almighty_env_users.include?(@user)
          error(client,'Only the environment administrators can set the "public" tag')
          return false
        end
        @demolishing_env = (
          cp.value('destructive',[TrueClass,FalseClass],false) ? 1 : 0
        )
        @environment_kind = cp.value('os',String,nil,OS_KIND)

        cp.parse('image',true) do
          file = cp.value('file',String)
          @tarball = {
            'kind' => EnvironmentManagement.image_type_short(
              cp.value('kind',String,nil,IMAGE_KIND),
              cp.value('compression',String,nil,IMAGE_COMPRESSION)
            ),
            'file' => file,
            'md5' => filemd5.call(file)
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

        cp.parse('boot') do
          @kernel = cp.value('kernel',String,'',Pathname)
          @initrd = cp.value('initrd',String,'',Pathname)
          @kernel_params = cp.value('kernel_params',String,'')
          @hypervisor = cp.value('hypervisor',String,'',Pathname)
          @hypervisor_params = cp.value('hypervisor_params',String,'')
        end

        @filesystem = cp.value('filesystem',String,'')
        @fdisk_type = cp.value('partition_type',Fixnum,0).to_s(16) #numeric or hexa

      rescue ArgumentError => ae
        error(client,"Error(#{(filename ? filename : 'env_desc')}) #{ae.message}")
        return false
      end

      ret = check_os_values()
      error(client,ret[1]) unless ret[0]
      return ret[0]
    end

    # Load an environment from a database
    #
    # Arguments
    # * name: environment name
    # * version: environment version
    # * user: environment owner
    # * true_user: true user
    # * dbh: database handler
    # * client: DRb handler to client
    # Output
    # * returns true if the environment can be loaded, false otherwise
    def load_from_db(name, version, specified_user, true_user, dbh, client)
      user = specified_user ? specified_user : true_user
      mask_private_env = true_user != user

      args = []

      query = "SELECT * FROM environments WHERE name=? AND user=?"
      args << name
      args << user
      query += " AND visibility <> 'private'" if mask_private_env

      if (version == nil) then
        subquery = "SELECT MAX(version) FROM environments WHERE name = ? AND user = ?"
        args << name
        args << user
        subquery += " AND visibility <> 'private'" if mask_private_env
        query += " AND version = (#{subquery})"
      else
        query += " AND version = ?"
        args << version.to_i
      end

      res = dbh.run_query(query, *args)
      tmp = res.to_hash if res
      if tmp and !tmp.empty? #We only take the first result since no other result should be returned
        load_from_hash(tmp[0])
        return true
      end

      #If no environment is found for the user, we check the public environments
      if (specified_user == nil) then
        args = []
        query = "SELECT * FROM environments WHERE name = ? AND user <> ? AND visibility = 'public'"
        args << name
        args << user

        if (version  == nil) then
          subquery = "SELECT MAX(version) FROM environments WHERE name = ? AND user <> ? AND visibility = 'public'"
          args << name
          args << user
          query += " AND version = (#{subquery})"
        else
          query += " AND version = ?"
          args << version
        end

        res = dbh.run_query(query, *args)

        tmp = res.to_hash if res
        if tmp and !tmp.empty? #We only take the first result since no other result should be returned
          load_from_hash(tmp[0])
          return true
        end
      end

      Debug::distant_client_error("The environment #{name} cannot be loaded. Maybe the version number does not exist or it belongs to another user", client)
      return false
    end

    # Load an environment from an Hash
    #
    # Arguments
    # * hash: hashtable
    # Output
    # * nothing
    def load_from_hash(hash)
      @id = hash["id"]
      @name = hash["name"]
      @version = hash["version"]
      @description = hash["description"]
      @author = hash["author"]
      @tarball = Hash.new
      val = hash["tarball"].split("|")
      @tarball["file"] = val[0]
      @tarball["kind"] = val[1]
      @tarball["md5"] = val[2]
      if (hash["preinstall"] != "") then
        @preinstall = Hash.new
        val = hash["preinstall"].split("|")
        @preinstall["file"] = val[0]
        @preinstall["kind"] = val[1]
        @preinstall["md5"] = val[2]
        @preinstall["script"] = val[3]
      else
        @preinstall = nil
      end
      if (hash["postinstall"] != "") then
        @postinstall = Array.new
        hash["postinstall"].split(",").each { |tmp|
          val = tmp.split("|")
          entry = Hash.new
          entry["file"] = val[0]
          entry["kind"] = val[1]
          entry["md5"] = val[2]
          entry["script"] = val[3]
          @postinstall.push(entry)
        }
      else
        @postinstall = nil
      end
      if (hash["kernel"] != "") then
        @kernel = hash["kernel"]
      else
        @kernel = nil
      end
      if (hash["kernel_params"] != "") then
        @kernel_params = hash["kernel_params"]
      else
        @kernel_params = nil
      end
      if (hash["initrd"] != "") then
        @initrd = hash["initrd"]
      else
        @initrd = nil
      end
      if (hash["hypervisor"] != "") then
        @hypervisor = hash["hypervisor"] 
      else
        @hypervisor = nil
      end
      if (hash["hypervisor_params"] != "") then
        @hypervisor_params = hash["hypervisor_params"]
      else
        @hypervisor_params = nil 
      end
      @fdisk_type = hash["fdisk_type"]
      if (hash["filesystem"] != "") then
        @filesystem = hash["filesystem"]
      else
        @filesystem = nil
      end
      @user = hash["user"]
      @environment_kind = hash["environment_kind"]
      @visibility = hash["visibility"]
      @demolishing_env = hash["demolishing_env"]
    end

    # Check the MD5 digest of the files
    #
    # Arguments
    # * nothing
    # Output
    # * returns true if the digest is OK, false otherwise
    def check_md5_digest
      val = @tarball.split("|")
      tarball_file = val[0]
      tarball_md5 = val[2]
      if (MD5::get_md5_sum(tarball_file) != tarball_md5) then
        return false
      end
      @postinstall.split(",").each { |entry|
        val = entry.split("|")
        postinstall_file = val[0]
        postinstall_md5 = val[2]
        if (MD5::get_md5_sum(postinstall_file) != postinstall_md5) then
          return false
        end       
      }
      return true
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
      ret['destructive'] = (@demolishing_env == 0 ? false : true)
      ret['os'] = @environment_kind

      ret['image'] = {}
      ret['image']['kind'],ret['image']['compression'] =
        EnvironmentManagement.image_type_long(@tarball['kind'])
      ret['image']['file'] = @tarball['file']

      unless @preinstall.nil?
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
      ret['boot'] = tmp unless tmp.empty?

      ret['filesystem'] = @filesystem if !@filesystem.nil? and !@filesystem.empty?
      ret['partition_type'] = @fdisk_type.to_i(16)

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

    def flatten_image(img,md5=false)
      "#{img['file']}|#{img['kind']}#{(md5 ? '|'+img['md5'] : '')}"
    end

    def expand_image(img,md5=false)
      ret = {}
      tmp=img.split('|')
      ret['file'],ret['kind'] = tmp
      ret['md5'] = tmp[2] if md5
      ret
    end

    def flatten_preinstall(pre,md5=false)
      if !pre.nil? and !pre.empty?
        "#{pre['file']}|#{pre['kind']}#{(md5 ? '|'+pre['md5'] : '')}|#{pre['script']}"
      else
        ''
      end
    end

    def expand_preinstall(pre,md5=false)
      if pre.nil?
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

    def flatten_postinstall(post,md5=false)
      if !post.nil? and !post.empty?
        post.collect do |p|
          "#{p['file']}|#{p['kind']}#{(md5 ? '|'+p['md5'] : '')}|#{p['script']}"
        end.join(',')
      else
        ''
      end
    end

    def expand_postinstall(post,md5=false)
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
      query = ""
      case kind
      when "tarball"
        tarball = "#{@tarball["file"]}|#{@tarball["kind"]}|#{hash}"
        query = "UPDATE environments SET tarball=\"#{tarball}\""
      when "presinstall"
        preinstall = "#{@preinstall["file"]}|#{@preinstall["kind"]}|#{hash}"
        query = "UPDATE environments SET presinstall=\"#{preinstall}\""
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
  end
end
