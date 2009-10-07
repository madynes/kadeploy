# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'db'
require 'md5'

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
    # * almighty_env_users: array that contains almighty users
    # Output
    # * returns true if the environment can be loaded correctly, false otherwise
    def load_from_file(file, almighty_env_users)
      if not File.exist?(file)
        put "The file \"#{file}\" does not exist"
        return false
      else
        @preinstall = nil
        @postinstall = nil
        @demolishing_env = "0"
        @kernel_params = nil
        @visibility = "shared"
        @user = `id -nu`.chomp
        @version = 0
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
                puts "The environment version must be a number"
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
                  puts "#{@tarball["file"]} is an HTTP file, let's bypass the md5sum"
                  @tarball["md5"] = ""
                else
                  if not File.readable?(@tarball["file"]) then
                    puts "The tarball file #{@tarball["file"]} cannot be read"
                    return false
                  end
                  puts "Computing the md5sum for #{@tarball["file"]}"
                  @tarball["md5"] = MD5::get_md5_sum(@tarball["file"])
                end
              else
                puts "The environment tarball must be described like filename|kind where kind is tgz, tbz2, ddgz, or ddbz2"
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
                  puts "#{@preinstall["file"]} is an HTTP file, let's bypass the md5sum"
                  @preinstall["md5"] = ""
                else
                  if not File.readable?(@preinstall["file"]) then
                    puts "The pre-install file #{@preinstall["file"]} cannot be read"
                    return false
                  end
                  puts "Computing the md5sum for #{@preinstall["file"]}"
                  @preinstall["md5"] = MD5::get_md5_sum(@preinstall["file"])
                end
              else
                puts "The environment preinstall must be described like filename|kind1|script where kind is tgz or tbz2"
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
                    puts "#{entry["file"]} is an HTTP file, let's bypass the md5sum"
                    entry["md5"] = ""
                  else
                    if not File.readable?(entry["file"]) then
                      puts "The post-install file #{entry["file"]} cannot be read"
                      return false
                    end
                    puts "Computing the md5sum for #{entry["file"]}"
                    entry["md5"] = MD5::get_md5_sum(entry["file"])
                  end
                  @postinstall.push(entry)
                }
              else
                puts "The environment postinstall must be described like filename1|kind1|script1,filename2|kind2|script2,...  where kind is tgz or tbz2"
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
                puts "The environment kind must be linux, xen or other"
                return false
              end
            when "visibility"
              if val =~ /\A(private|shared|public)\Z/ then
                @visibility = val
                if (@visibility == "public") && (not almighty_env_users.include?(@user)) then
                  puts "Only the environment administrators can set the \"public\" tag"
                  return false
                end
              else
                puts "The environment visibility must be private, shared or public"
                return false
              end
            when "demolishing_env"
              if val =~ /\A\d+\Z/ then
                @demolishing_env = val
              else
                puts "The environment demolishing_env must be a number"
                return false
              end
            else
              puts "#{attr} is an invalid attribute"
              return false
            end
          end
        }
      end
      if ((@name == nil) || (@tarball == nil) || (@kernel == nil) ||
          (@initrd == nil) || (@fdisk_type == nil) || (@filesystem == nil) || (@environment_kind == nil)) then
        puts "The name, tarball, kernel, initrd, fdisktype, filesystem and environment_kind fileds are mandatory"
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
    # * dbh: database handler
    # Output
    # * returns true if the environment can be loaded, false otherwise
    def load_from_db(name, version, user, dbh)
      true_user = `id -nu`.chomp
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
      
      puts "The environment #{name} cannot be loaded. Maybe the version number does not exist or it belongs to another user"
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
      @kernel = hash["kernel"]
      if (hash["kernel_params"] != "") then
        @kernel_params = hash["kernel_params"]
      else
        @kernel_params = nil
      end
      @initrd = hash["initrd"]
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
      @filesystem = hash["filesystem"]
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
    def short_view_header
      puts "Name                Version     User            Description"
      puts "####                #######     ####            ###########"
    end

    # Print the short view
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def short_view
      printf("%-21s %-7s %-10s %-40s\n", @name, @version, @user, @description)
    end

    # Print the full view
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def full_view
      puts "name : #{@name}"
      puts "version : #{@version}"
      puts "description : #{@description}"
      puts "author : #{@author}"
      puts "tarball : #{flatten_tarball()}"
      puts "preinstall : #{flatten_pre_install()}" if (@preinstall != nil)
      puts "postinstall : #{flatten_post_install()}" if (@postinstall != nil)
      puts "kernel : #{@kernel}"
      puts "kernel_params : #{@kernel_params}" if (@kernel_params != nil)
      puts "initrd : #{@initrd}"
      puts "hypervisor : #{@hypervisor}" if (@hypervisor != nil)
      puts "hypervisor_params : #{@hypervisor_params}" if (@hypervisor_params != nil)
      puts "fdisktype : #{@fdisk_type}"
      puts "filesystem : #{@filesystem}"
      puts "environment_kind : #{@environment_kind}"
      puts "visibility : #{@visibility}"
      puts "demolishing_env : #{@demolishing_env}"
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
