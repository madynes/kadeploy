# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2012
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'debug'
require 'nodes'
require 'config'
require 'cache'
require 'md5'
require 'http'
require 'error'

#Ruby libs
require 'thread'
require 'uri'
require 'tempfile'

module Managers
  class GrabFileManager
    include Printer
    @config = nil
    @output = nil
    @client = nil
    @db = nil

    # Constructor of GrabFileManager
    #
    # Arguments
    # * config: instance of Config
    # * output: instance of OutputControl
    # * client : Drb handler of the client
    # * db: database handler
    # Output
    # * nothing
    def initialize(config, output, client, db)
      @config = config
      @output = output
      @client = client
      @db = db
    end

    # Grab a file from the client side or locally with recording the hash of the file
    #
    # Arguments
    # * client_file: client file to grab
    # * local_file: path to local cached file
    # * expected_md5: expected md5 for the client file
    # * file_tag: tag used to specify the kind of file to grab
    # * prefix: prefix used to store the file in the cache
    # * cache_dir: cache directory
    # * cache_size: cache size
    # * async (opt) : specify if the caller client is asynchronous
    # Output
    # * return true if everything is successfully performed, false otherwise
    def grab_file_with_caching(client_file, local_file, expected_md5, file_tag, prefix, cache_dir, cache_size, async = false, cache_pattern = /./)
      #http fetch
      if (client_file =~ /^http[s]?:\/\//) then
        @output.verbosel(3, "Grab the #{file_tag} file #{client_file} over http")
        file_size = HTTP::get_file_size(client_file)
        if file_size == nil then
          @output.verbosel(0, "Cannot reach the file at #{client_file}")
          return false
        end
        Cache::clean_cache(cache_dir,
                           (cache_size * 1024 * 1024) -  file_size,
                           0.5, cache_pattern,
                           @output)
        if (not File.exist?(local_file)) then
          resp,etag = HTTP::fetch_file(client_file, local_file, cache_dir, nil)
          case resp
          when -1
            @output.verbosel(0, "Tempfiles cannot be created")
            raise TempfileException
          when -2
            @output.verbosel(0, "Environment file cannot be moved")
            raise MoveException
          when "200"
            @output.verbosel(5, "File #{client_file} fetched")
          else
            @output.verbosel(0, "Cannot fetch the file at #{client_file}, http error #{resp}")
            return false
          end

          if not @config.exec_specific.environment.set_md5(file_tag, client_file, etag.gsub("\"",""), @db) then
            @output.verbosel(0, "Cannot update the md5 of #{client_file}")
            return false
          end
        else
          resp,etag = HTTP::fetch_file(client_file, local_file, cache_dir, expected_md5)
          case resp
          when -1
            @output.verbosel(0, "Tempfiles cannot be created")
            raise TempfileException
          when -2
            @output.verbosel(0, "Environment file cannot be moved")
            raise MoveException
          when "200"
            @output.verbosel(5, "File #{client_file} fetched")
            if not @config.exec_specific.environment.set_md5(file_tag, client_file, etag.gsub("\"",""), @db) then
              @output.verbosel(0, "Cannot update the md5 of #{client_file}")
              return false
            end
          when "304"
            @output.verbosel(5, "File #{client_file} already in cache")
            if not system("touch -a #{local_file}") then
              @output.verbosel(0, "Unable to touch the local file")
              return false
            end
          else
            @output.verbosel(0, "Cannot fetch the file at #{client_file}, http error: #{resp}")
            return false
          end
        end
      #classical fetch
      else
        if ((not File.exist?(local_file)) || (MD5::get_md5_sum(local_file) != expected_md5)) then
          #We first check if the file can be reached locally
          if (File.readable?(client_file) && (MD5::get_md5_sum(client_file) == expected_md5)) then
            Cache::clean_cache(cache_dir,
                               (cache_size * 1024 * 1024) -  File.stat(client_file).size,
                               0.5, cache_pattern,
                               @output)
            @output.verbosel(3, "Caching the #{file_tag} file #{client_file}")
            if not system("cp #{client_file} #{local_file}") then
              @output.verbosel(0, "Unable to cache (#{client_file} to #{local_file})")
              return false
            else
              if not system("chmod 640 #{local_file}") then
                @output.verbosel(0, "Unable to change the rights on #{local_file}")
                return false
              end
            end
          else
            if async then
              @output.verbosel(0, "Only http transfer is allowed in asynchronous mode")
              return false
            else
              Cache::clean_cache(cache_dir,
                                 (cache_size * 1024 * 1024) - @client.get_file_size(client_file),
                                 0.5, cache_pattern,
                                 @output)
              @output.verbosel(3, "Grab the #{file_tag} file #{client_file}")
              if (@client.get_file_md5(client_file) != expected_md5) then
                @output.verbosel(0, "The md5 of #{client_file} does not match with the one recorded in the database, please consider to update your environment")
                return false
              end
              if not @client.get_file(client_file, prefix, cache_dir) then
                @output.verbosel(0, "Unable to grab the #{file_tag} file #{client_file}")
                return false
              end
            end
          end
        else
          if (not async) then
            if (File.readable?(client_file)) then
              #the file is reachable on the local filesystem
              get_mtime = lambda { return File.mtime(client_file).to_i }
              get_md5 = lambda { return MD5::get_md5_sum(client_file) }
            else
              #the file is only reachable by the client
              get_mtime = lambda { return @client.get_file_mtime(client_file) }
              get_md5 = lambda { return @client.get_file_md5(client_file) }
            end
            if (File.mtime(local_file).to_i < get_mtime.call) then
              if (get_md5.call  != expected_md5) then
                @output.verbosel(0, "!!! Warning !!! The file #{client_file} has been modified, you should run kaenv3 to update its MD5")
              else
                if not system("touch -m #{local_file}") then
                  @output.verbosel(0, "Unable to touch the local file")
                  return false
                end
              end
            end
          end
          if not system("touch -a #{local_file}") then
            @output.verbosel(0, "Unable to touch the local file")
            return false
          end
        end
      end
      return true
    end

    # Grab a file from the client side or locally without recording the hash of the file
    #
    # Arguments
    # * client_file: client file to grab
    # * local_file: path to local cached file
    # * file_tag: tag used to specify the kind of file to grab
    # * prefix: prefix used to store the file in the cache
    # * cache_dir: cache directory
    # * cache_size: cache size
    # * async (opt) : specify if the caller client is asynchronous
    # Output
    # * return true if everything is successfully performed, false otherwise
    def grab_file_without_caching(client_file, local_file, file_tag, prefix, cache_dir, cache_size, async = false, cache_pattern = /./)
      #http fetch
      if (client_file =~ /^http[s]?:\/\//) then
        @output.verbosel(3, "Grab the #{file_tag} file #{client_file} over http")
        file_size = HTTP::get_file_size(client_file)
        if file_size == nil then
          @output.verbosel(0, "Cannot reach the file at #{client_file}")
          return false
        end
        Cache::clean_cache(cache_dir,
                           (cache_size * 1024 * 1024) -  file_size,
                           0.5, cache_pattern,
                           @output)
        resp,etag = HTTP::fetch_file(client_file, local_file, cache_dir, nil)
        case resp
        when -1
          @output.verbosel(0, "Tempfiles cannot be created")
          raise TempfileException
        when -2
          @output.verbosel(0, "Environment file cannot be moved")
          raise MoveException
        when "200"
          @output.verbosel(5, "File #{client_file} fetched")
        else
          @output.verbosel(0, "Unable to grab the #{file_tag} file #{client_file}, http error #{resp}")
          return false
        end
      #classical fetch
      else
        if File.readable?(client_file) then
          Cache::clean_cache(cache_dir,
                             (cache_size * 1024 * 1024) -  File.stat(client_file).size,
                             0.5, cache_pattern,
                             @output)
          @output.verbosel(3, "Caching the #{file_tag} file #{client_file}")
          if not system("cp #{client_file} #{local_file}") then
            @output.verbosel(0, "Unable to cache (#{client_file} to #{local_file})")
            return false
          else
            if not system("chmod 640 #{local_file}") then
              @output.verbosel(0, "Unable to change the rights on #{local_file}")
              return false
            end
          end
        else
          if async then
            @output.verbosel(0, "Only http transfer is allowed in asynchronous mode")
            return false
          else
            @output.verbosel(3, "Grab the #{file_tag} file #{client_file}")
            Cache::clean_cache(cache_dir,
                               (cache_size * 1024 * 1024) - @client.get_file_size(client_file),
                               0.5, cache_pattern,
                               @output)
            if not @client.get_file(client_file, prefix, cache_dir) then
              @output.verbosel(0, "Unable to grab the file #{client_file}")
              return false
            end
          end
        end
      end
      return true
    end

    # Grab a file from the client side or locally
    #
    # Arguments
    # * client_file: client file to grab
    # * local_file: path to local cached file
    # * expected_md5: expected md5 for the client file
    # * file_tag: tag used to specify the kind of file to grab
    # * prefix: prefix used to store the file in the cache
    # * cache_dir: cache directory
    # * cache_size: cache size
    # * async (opt) : specify if the caller client is asynchronous
    # Output
    # * return true if everything is successfully performed, false otherwise
    def grab_file(client_file, local_file, expected_md5, file_tag, prefix, cache_dir, cache_size, async = false,cache_pattern=/./)
      #anonymous environment
      if (@config.exec_specific.load_env_kind == "file") then
        return grab_file_without_caching(client_file, local_file, file_tag, prefix, cache_dir, cache_size, async, cache_pattern)
      #recorded environement
      else
        return grab_file_with_caching(client_file, local_file, expected_md5, file_tag, prefix, cache_dir, cache_size, async, cache_pattern)
      end
    end

    def self.error(errno,context)
      #@errno = errno
      #@nodes.set_deployment_state('aborted',nil,context[:database],'') if abrt
      raise KadeployError.new(errno,context)
    end

    def self.grab_file_client(gfm,context,remotepath,prefix,filetag,errno,opts={})
      return unless remotepath

      cachedir,cachesize,pattern = nil
      case opts[:cache]
        when :kernels
          cachedir = File.join(
            context[:common].pxe_repository,
            context[:common].pxe_repository_kernels
          )
          cachesize = context[:common].pxe_repository_kernels_max_size
          pattern = /^(e\d+--.+)|(e-anon-.+)|(pxe-.+)$/
        #when :kadeploy
        else
          cachedir = context[:common].kadeploy_cache_dir
          cachesize = context[:common].kadeploy_cache_size
          pattern = /./
      end

      localpath = File.join(cachedir, "#{prefix}#{File.basename(remotepath)}")

      begin
        res = nil

        if opts[:caching]
          res = gfm.grab_file(
            remotepath,
            localpath,
            opts[:md5],
            filetag,
            prefix,
            cachedir,
            cachesize,
            context[:async],
            pattern
          )
        else
          res = gfm.grab_file_without_caching(
            remotepath,
            localpath,
            filetag,
            prefix,
            cachedir,
            cachesize,
            context[:async],
            pattern
          )
        end

        if res and opts[:maxsize]
          if (File.size(localpath) / 1024**2) > opts[:maxsize]
            debug(0,
              "The #{filetag} file #{remotepath} is too big "\
              "(#{opts[:maxsize]} MB is the maximum size allowed)"
            )
            File.delete(localpath)
            error(opts[:error_maxsize],context)
          end
        end

        error(errno,context) unless res
      rescue TempfileException
        error(FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE,context)
      rescue MoveException
        error(FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE,context)
      end

      if opts[:mode]
        if not system("chmod #{opts[:mode]} #{localpath}") then
          debug(0, "Unable to change the rights on #{localpath}")
          return false
        end
      end

      remotepath.gsub!(remotepath,localpath) if !opts[:noaffect] and localpath
    end

    def self.grab_user_files(context,output)
      env_prefix = context[:execution].prefix_in_cache
      user_prefix = "u-#{context[:execution].true_user}--"

      gfm = Managers::GrabFileManager.new(
        context[:config], output,
        context[:client], context[:database]
      )

      # Env tarball
      file = context[:execution].environment.tarball
      grab_file_client(
        gfm, context, file['file'], env_prefix, 'tarball',
        FetchFileError::INVALID_ENVIRONMENT_TARBALL,
        :md5 => file['md5'], :caching => true
      )

      # SSH key file
      if file = context[:execution].key and !file.empty?
        grab_file_client(
          gfm, context, file, user_prefix, 'key',
          FetchFileError::INVALID_KEY, :caching => false
        )
      end

      # Preinstall archive
      if file = context[:execution].environment.preinstall
        grab_file_client(
          gfm, context, file['file'], env_prefix, 'preinstall',
          FetchFileError::INVALID_PREINSTALL,
          :md5 => file['md5'], :caching => true,
          :maxsize => context[:common].max_preinstall_size,
          :error_maxsize => FetchFileError::PREINSTALL_TOO_BIG
        )
      end

      # Postinstall archive
      if context[:execution].environment.postinstall
        context[:execution].environment.postinstall.each do |file|
          grab_file_client(
            gfm, context, file['file'], env_prefix, 'postinstall',
            FetchFileError::INVALID_POSTINSTALL,
            :md5 => file['md5'], :caching => true,
            :maxsize => context[:common].max_postinstall_size,
            :error_maxsize => FetchFileError::POSTINSTALL_TOO_BIG
          )
        end
      end

      # Custom files
      if context[:execution].custom_operations
        context[:execution].custom_operations[:operations].each_pair do |macro,micros|
          micros.each_pair do |micro,entries|
            entries.each do |entry|
              if entry[:action] == :send
                entry[:filename] = File.basename(entry[:file].dup)
                grab_file_client(
                  gfm, context, entry[:file], user_prefix, 'custom_file',
                  FetchFileError::INVALID_CUSTOM_FILE, :caching => false
                )
              elsif entry[:action] == :run
                grab_file_client(
                  gfm, context, entry[:file], user_prefix, 'custom_file',
                  FetchFileError::INVALID_CUSTOM_FILE, :caching => false
                )
              end
            end
          end
        end
      end

      # Custom PXE files
      if context[:execution].pxe_profile_msg != ''
        unless context[:execution].pxe_upload_files.empty?
          context[:execution].pxe_upload_files.each do |pxefile|
            grab_file_client(
              gfm, context, pxefile, "pxe-#{context[:execution].true_user}--", 'pxe_file',
              FetchFileError::INVALID_PXE_FILE, :caching => false,
              :cache => :kernels, :noaffect => true, :mode => '744'
            )
          end
        end
      end
    end
  end
end

