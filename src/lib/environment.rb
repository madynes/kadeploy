# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Ruby libs
require 'tempfile'

#Kadeploy libs
require 'db'
require 'md5'
require 'http'
require 'debug'

module EnvironmentManagement
  class Environment
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

    # Load an environment file
    #
    # Arguments
    # * file: filename
    # * file_content: environment description
    # * almighty_env_users: array that contains almighty users
    # * user: true user
    # * cache_dir: cache directory
    # * client: DRb handler to client
    # * record_step: specify if the function is called for a DB record purpose
    # Output
    # * returns true if the environment can be loaded correctly, false otherwise
    def load_from_file(file, file_content, almighty_env_users, user, cache_dir, client, record_in_db)
      begin
        temp_env_file = Tempfile.new("env_file")
      rescue StandardException
        Debug::distant_client_error("Temporary directory is full on the server side, please contact the administrator", client)
        return false
      end
      if (file =~ /^http[s]?:\/\//) then
        http_response, etag = HTTP::fetch_file(file, temp_env_file.path, cache_dir, nil)
        case http_response
        when -1
          Debug::distant_client_error("The file #{file} cannot be fetched: impossible to create a tempfile in the cache directory", client)
          return false
        when -2
          Debug::distant_client_error("The file #{file} cannot be fetched: impossible to move the file in the cache directory", client)
          return false
        when "200"
        else
          Debug::distant_client_error("The file #{file} cannot be fetched: http_response #{http_response}", client)
          return false
        end
      else
        if not system("echo \"#{file_content}\" > #{temp_env_file.path}") then
          Debug::distant_client_error("Cannot write the environment file", client)
          return false
        end
      end
      file = temp_env_file.path
      @preinstall = nil
      @postinstall = nil
      @environment_kind = nil
      @demolishing_env = "0"
      @author = "no author"
      @description = "no description"
      @kernel = nil
      @kernel_params = nil
      @initrd = nil
      @hypervisor = nil
      @hypervisor_params = nil
      @fdisk_type = nil
      @filesystem = nil
      @visibility = "shared"
      @user = user
      @version = 0
      @id = -1
      IO::read(file).split("\n").each { |line|
        if /\A(\w+)\ :\ (.+)\Z/ =~ line then
          content = Regexp.last_match
          attr = content[1]
          val = content[2]
          case attr
          when "name"
            @name = val
          when "version"
            if val =~ /\A\d+\Z/ then
              @version = val
            else
              Debug::distant_client_error("The environment version must be a number", client)
              return false
            end
          when "description"
            @description = val
          when "author"
            @author = val
          when "tarball"
            #filename|tgz
            if val =~ /\A.+\|(tgz|tbz2|ddgz|ddbz2)\Z/ then
              @tarball = Hash.new
              tmp = val.split("|")
              @tarball["file"] = tmp[0]
              @tarball["kind"] = tmp[1]
              if @tarball["file"] =~ /^http[s]?:\/\// then
                Debug::distant_client_print("#{@tarball["file"]} is an HTTP file, let's bypass the md5sum", client)
                @tarball["md5"] = ""
              else
                if (record_in_db) then
                  md5 = client.get_file_md5(@tarball["file"])
                  if (md5 != 0) then
                    @tarball["md5"] = md5
                  else
                    Debug::distant_client_error("The tarball file #{@tarball["file"]} cannot be read", client)
                    return false
                  end
                end
              end
            else
              Debug::distant_client_error("The environment tarball must be described like filename|kind where kind is tgz, tbz2, ddgz, or ddbz2", client)
              return false
            end
          when "preinstall"
            if val =~ /\A.+\|(tgz|tbz2)\|.+\Z/ then
              entry = val.split("|")
              @preinstall = Hash.new
              @preinstall["file"] = entry[0]
              @preinstall["kind"] = entry[1]
              @preinstall["script"] = entry[2]
              if @preinstall["file"] =~ /^http[s]?:\/\// then
                Debug::distant_client_print("#{@preinstall["file"]} is an HTTP file, let's bypass the md5sum", client)
                @preinstall["md5"] = ""
              else
                if (record_in_db) then
                  md5 = client.get_file_md5(@preinstall["file"])
                  if (md5 != 0) then
                    @preinstall["md5"] = md5
                  else
                    Debug::distant_client_error("The pre-install file #{@preinstall["file"]} cannot be read", client)
                    return false
                  end
                end
              end
            else
              Debug::distant_client_error("The environment preinstall must be described like filename|kind1|script where kind is tgz or tbz2", client)
              return false
            end
          when "postinstall"
            #filename|tgz|script,filename|tgz|script...
            if val =~ /\A.+\|(tgz|tbz2)\|.+(,.+\|(tgz|tbz2)\|.+)*\Z/ then
              @postinstall = Array.new
              val.split(",").each { |tmp|
                tmp2 = tmp.split("|")
                entry = Hash.new
                entry["file"] = tmp2[0]
                entry["kind"] = tmp2[1]
                entry["script"] = tmp2[2]
                if entry["file"] =~ /^http[s]?:\/\// then
                  Debug::distant_client_print("#{entry["file"]} is an HTTP file, let's bypass the md5sum", client)
                  entry["md5"] = ""
                else
                  if (record_in_db) then
                    md5 = client.get_file_md5(entry["file"])
                    if (md5 != 0) then
                      entry["md5"] = md5
                    else
                      Debug::distant_client_error("The post-install file #{entry["file"]} cannot be read", client)
                      return false
                    end
                  end
                end
                @postinstall.push(entry)
              }
            else
              Debug::distant_client_error("The environment postinstall must be described like filename1|kind1|script1,filename2|kind2|script2,...  where kind is tgz or tbz2", client)
              return false
            end
          when "kernel"
            @kernel = val
          when "kernel_params"
            @kernel_params = val
          when "initrd"
            @initrd = val
          when "hypervisor"
            @hypervisor = val
          when "hypervisor_params"
            @hypervisor_params = val
          when "fdisktype"
            @fdisk_type = val
          when "filesystem"
            @filesystem = val
          when "environment_kind"
            if val =~ /\A(linux|xen|other)\Z/ then
              @environment_kind = val
            else
              Debug::distant_client_error("The environment kind must be linux, xen or other", client)
              return false
            end
          when "visibility"
            if val =~ /\A(private|shared|public)\Z/ then
              @visibility = val
              if (@visibility == "public") && (not almighty_env_users.include?(@user)) then
                Debug::distant_client_error("Only the environment administrators can set the \"public\" tag", client)
                return false
              end
            else
              Debug::distant_client_error("The environment visibility must be private, shared or public", client)
              return false
            end
          when "demolishing_env"
            if val =~ /\A\d+\Z/ then
              @demolishing_env = val
            else
              Debug::distant_client_error("The environment demolishing_env must be a number", client)
              return false
            end
          else
            Debug::distant_client_error("#{attr} is an invalid attribute", client)
            return false
          end
        end
      }
      case @environment_kind
      when "linux"
        if ((@name == nil) || (@tarball == nil) || (@kernel == nil) ||(@fdisk_type == nil) || (@filesystem == nil)) then
          Debug::distant_client_error("The name, tarball, kernel, fdisktype, filesystem, and environment_kind fields are mandatory", client)
          return false
        end
      when "xen"
        if ((@name == nil) || (@tarball == nil) || (@kernel == nil) || (@hypervisor == nil) ||(@fdisk_type == nil) || (@filesystem == nil)) then
          Debug::distant_client_error("The name, tarball, kernel, hypervisor, fdisktype, filesystem, and environment_kind fields are mandatory", client)
          return false
        end
      when "other"
        if ((@name == nil) || (@tarball == nil) ||(@fdisk_type == nil)) then
          Debug::distant_client_error("The name, tarball, fdisktype, and environment_kind fields are mandatory", client)
          return false
        end        
      when nil
        Debug::distant_client_error("The environment_kind field is mandatory", client)
        return false       
      end
      return true
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
    def load_from_db(name, version, user, true_user, dbh, client)
      mask_private_env = false
      if (true_user != user) then
        mask_private_env = true
      end
      if (version == nil) then
        if mask_private_env then
          query = "SELECT * FROM environments WHERE name=\"#{name}\" \
                                              AND user=\"#{user}\" \
                                              AND visibility<>\"private\" \
                                              AND version=(SELECT MAX(version) FROM environments WHERE user=\"#{user}\" \
                                                                                                 AND visibility<>\"private\" \
                                                                                                 AND name=\"#{name}\")"
        else
          query = "SELECT * FROM environments WHERE name=\"#{name}\" \
                                              AND user=\"#{user}\" \
                                              AND version=(SELECT MAX(version) FROM environments WHERE user=\"#{user}\" \
                                                                                                 AND name=\"#{name}\")"

        end
      else
        if mask_private_env then
          query = "SELECT * FROM environments WHERE name=\"#{name}\" \
                                              AND user=\"#{user}\" \
                                              AND visibility<>\"private\" \
                                              AND version=\"#{version}\""
        else
          query = "SELECT * FROM environments WHERE name=\"#{name}\" \
                                              AND user=\"#{user}\" \
                                              AND version=\"#{version}\""
        end
      end
      res = dbh.run_query(query)
      row = res.fetch_hash
      if (row != nil) #We only take the first result since no other result should be returned
        load_from_hash(row)
        return true
      end
      
      #If no environment is found for the user, we check the public environments
      if (true_user == user) then
        if (version  == nil) then
          query = "SELECT * FROM environments WHERE name=\"#{name}\" \
                                              AND user<>\"#{user}\" \
                                              AND visibility=\"public\" \
                                              AND version=(SELECT MAX(version) FROM environments WHERE user<>\"#{user}\" \
                                                                                                 AND visibility=\"public\" \
                                                                                                 AND name=\"#{name}\")"
        else
          query = "SELECT * FROM environments WHERE name=\"#{name}\" \
                                              AND user<>\"#{user}\" \
                                              AND visibility=\"public\" \
                                              AND version=\"#{version}\""
        end
        res = dbh.run_query(query)
        row = res.fetch_hash
        if (row != nil) #We only take the first result since no other result should be returned
          load_from_hash(row)
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

    # Print the full view
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def full_view(client)
      out = String.new
      out += "name : #{@name}\n"
      out += "version : #{@version}\n"
      out += "description : #{@description}\n"
      out += "author : #{@author}\n"
      out += "tarball : #{flatten_tarball()}\n"
      out += "preinstall : #{flatten_pre_install()}\n" if (@preinstall != nil)
      out += "postinstall : #{flatten_post_install()}\n" if (@postinstall != nil)
      out += "kernel : #{@kernel}\n" if (@kernel != nil)
      out += "kernel_params : #{@kernel_params}\n" if (@kernel_params != nil)
      out += "initrd : #{@initrd}\n" if (@initrd != nil)
      out += "hypervisor : #{@hypervisor}\n" if (@hypervisor != nil)
      out += "hypervisor_params : #{@hypervisor_params}\n" if (@hypervisor_params != nil)
      out += "fdisktype : #{@fdisk_type}\n"
      out += "filesystem : #{@filesystem}\n" if (@filesystem != nil)
      out += "environment_kind : #{@environment_kind}\n"
      out += "visibility : #{@visibility}\n"
      out += "demolishing_env : #{@demolishing_env}\n"
      Debug::distant_client_print(out, client)
    end

    # Give the flatten view of the tarball info without the md5sum
    #
    # Arguments
    # * nothing
    # Output
    # * return a string containing the tarball info without the md5sum
    def flatten_tarball
      return "#{@tarball["file"]}|#{@tarball["kind"]}"
    end

    # Give the flatten view of the pre-install info without the md5sum
    #
    # Arguments
    # * nothing
    # Output
    # * return a string containing the pre-install info without the md5sum
    def flatten_pre_install
      return "#{@preinstall["file"]}|#{@preinstall["kind"]}|#{@preinstall["script"]}"
    end

    # Give the flatten view of the post-install info without the md5sum
    #
    # Arguments
    # * nothing
    # Output
    # * return a string containing the post-install info without the md5sum
    def flatten_post_install
      out = Array.new
      if (@postinstall != nil) then
        @postinstall.each { |p|
          out.push("#{p["file"]}|#{p["kind"]}|#{p["script"]}")
        }
      end
      return out.join(",")
    end

    # Give the flatten view of the tarball info with the md5sum
    #
    # Arguments
    # * nothing
    # Output
    # * return a string containing the tarball info with the md5sum
    def flatten_tarball_with_md5
      return "#{@tarball["file"]}|#{@tarball["kind"]}|#{@tarball["md5"]}"
    end

    # Give the flatten view of the pre-install info with the md5sum
    #
    # Arguments
    # * nothing
    # Output
    # * return a string containing the pre-install info with the md5sum
    def flatten_pre_install_with_md5
      s = String.new
      if (@preinstall != nil) then
        s = "#{@preinstall["file"]}|#{@preinstall["kind"]}|#{@preinstall["md5"]}|#{@preinstall["script"]}"
      end
      return s
    end

    # Give the flatten view of the post-install info with the md5sum
    #
    # Arguments
    # * nothing
    # Output
    # * return a string containing the post-install info with the md5sum
    def flatten_post_install_with_md5
      out = Array.new
      if (@postinstall != nil) then
        @postinstall.each { |p|
          out.push("#{p["file"]}|#{p["kind"]}|#{p["md5"]}|#{p["script"]}")
        }
      end
      return out.join(",")
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
      query = String.new
      case kind
      when "tarball"
        tarball = "#{@tarball["file"]}|#{@tarball["kind"]}|#{hash}"
        query = "UPDATE environments SET tarball=\"#{tarball}\" WHERE id=\"#{@id}\""
      when "presinstall"
        preinstall = "#{@preinstall["file"]}|#{@preinstall["kind"]}|#{hash}"
        query = "UPDATE environments SET presinstall=\"#{preinstall}\" WHERE id=\"#{@id}\""
      when "postinstall"
        postinstall_array = Array.new
        @postinstall.each { |p|
          if (file == p["file"]) then
            postinstall_array.push("#{p["file"]}|#{p["kind"]}|#{hash}|#{p["script"]}")
          else
            postinstall_array.push("#{p["file"]}|#{p["kind"]}|#{p["md5"]}|#{p["script"]}")
          end
        }
        query = "UPDATE environments SET postinstall=\"#{postinstall_array.join(",")}\" WHERE id=\"#{@id}\""
      end
      dbh.run_query(query)
      return true
    end
  end
end
