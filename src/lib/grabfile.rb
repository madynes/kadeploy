# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2012
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'debug'
require 'nodes'
require 'cache'
require 'md5'
require 'http'
require 'error'
require 'netboot'

#Ruby libs
require 'thread'
require 'uri'
require 'fileutils'
require 'tempfile'

module Managers
  class Fetch
    def initialize(path,errno,client)
      @path = path
      @errno = errno
      @client = client
    end

    def self.[](path,errno,client=nil)
      kind = URI.parse(path).scheme || 'local'
      case kind
      when 'local'
        fetcher = LocalFetch.new(path,errno,client)
      when 'http','https'
        fetcher = HTTPFetch.new(path,errno,client)
      else
        raise KadeployError.new(
          FetchFileError::UNKNOWN_PROTOCOL,nil,
          "Unable to grab the file '#{path}', unknown protocol #{kind}"
        )
      end
      fetcher
    end

    def error(errno,msg)
      #@client.print("Error: #{msg}") if @client
      raise KadeployError.new(errno,nil,msg)
    end

    def uptodate?(fchecksum,fmtime=nil)
      !((mtime != fmtime) and (checksum != fchecksum))
    end

    def size
      raise 'Should be reimplemented'
    end

    def checksum
      raise 'Should be reimplemented'
    end

    def mtime
      raise 'Should be reimplemented'
    end

    def grab(dest,dir=nil)
      raise 'Should be reimplemented'
    end
  end

  class LocalFetch < Fetch
    def size
      if File.readable?(@path)
        File.size(@path)
      elsif @client
        if (ret = @client.get_file_size(@path)) == 0
          error(@errno,"Unable to grab the file #{@path}")
        end
        ret
      else
        error(@errno,"Unable to grab the file #{@path}")
      end
    end

    def checksum
      if File.readable?(@path)
        MD5::get_md5_sum(@path)
      elsif @client
        if (ret = @client.get_file_md5(@path)) == 0
          error(@errno,"Unable to grab the file #{@path}")
        end
        ret
      else
        error(@errno,"Unable to grab the file #{@path}")
      end
    end

    def mtime
      if File.readable?(@path)
        File.mtime(@path).to_i
      elsif @client
        if (ret = @client.get_file_mtime(@path)) == 0
          error(@errno,"Unable to grab the file #{@path}")
        end
        ret
      else
        error(@errno,"Unable to grab the file #{@path}")
      end
    end

    def grab(dest,dir=nil)
      if File.readable?(@path)
        begin
          FileUtils.cp(@path,dest)
        rescue Exception => e
          error(@errno,"Unable to grab the file #{@path} (#{e.message})")
        end
      elsif @client
        begin
          unless @client.get_file(@path,dest)
            error(@errno,"Unable to grab the file #{@path}")
          end
        rescue Exception => e
          error(@errno,"Unable to grab the file #{@path} (#{e.message})")
        end
      else
        error(@errno,"Unable to grab the file #{@path}")
      end
    end
  end

  class HTTPFetch < Fetch
    def size
      begin
        HTTP::get_file_size(@path)
      rescue KadeployHTTPError => k
        error(@errno,"Unable to grab the file #{@path} (http error ##{k.errno})")
      rescue Errno::ECONNREFUSED
        error(@errno,"Unable to grab the file #{@path} (connection refused)")
      rescue Exception => e
        error(@errno,"Unable to grab the file #{@path} (#{e.message})")
      end
    end

    def checksum
      begin
        resp, etag = HTTP.check_file(@path)
        case resp
        when 200,304
          nil
        else
          error(@errno,"Unable to grab the file #{@path} (http error ##{resp})")
        end
        etag
      rescue Exception => e
        error(@errno,"Unable to grab the file #{@path} (#{e.message})")
      end
    end

    def mtime
      begin
        HTTP::get_file_mtime(@path)
      rescue KadeployHTTPError => k
        error(@errno,"Unable to grab the file #{@path} (http error ##{k.errno})")
      rescue Errno::ECONNREFUSED
        error(@errno,"Unable to grab the file #{@path} (connection refused)")
      rescue Exception => e
        error(@errno,"Unable to grab the file #{@path} (#{e.message})")
      end
    end

    def grab(dest,dir=nil)
      begin
        resp, _ = HTTP.fetch_file(@path,dest,dir,nil)
        case resp
        when -1
          error(FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE,
            "Tempfiles cannot be created")
        when -2
          error(FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE,
            "Environment file cannot be moved")
        when 200
          nil
        else
          error(@errno,"Unable to grab the file #{@path} (http error ##{resp})")
        end
      rescue Exception => e
        error(@errno,"Unable to grab the file #{@path} (#{e.message})")
      end
    end
  end

  class GrabFileManager
    include Printer
    @config = nil
    @output = nil
    @client = nil
    @files = nil
    @db = nil
    attr_accessor :files

    def initialize(cache, output, client, db, mode=0640)
      @cache = cache
      @output = output
      @client = client
      @db = db
      @mode = mode
      @files = []
    end

    def error(errno,msg)
      #@output.verbosel(0, "Error: #{msg}")
      clean()
      raise KadeployError.new(errno,nil,msg)
    end

    def debug(msg)
      @output.verbosel(0, "Warning: #{msg}")
    end

    def clean()
      @files.each do |file|
        file.release
      end
      @cache.clean()
    end

    def grab(path,version,user,priority,tag,errno,checksum=nil,opts={})
      return nil if !path or path.empty?
      cf = nil
      begin
        fetcher = Fetch[path,errno,@client]

        if fetcher.size > @cache.maxsize
          error(FetchFileError::CACHE_FILE_TOO_BIG,
            "Impossible to cache the file '#{path}', the file is too big for the cache")
        end

        if opts[:maxsize] and fetcher.size > opts[:maxsize]
          error(opts[:maxsize_errno],
            "The #{tag} file '#{path}' is too big "\
            "(#{opts[:maxsize]/(1024*1024)} MB is the max size)"
          )
        end

        fmtime = lambda{ fetcher.mtime }
        fchecksum = lambda{ fetcher.checksum }
        fpath = nil
        fpath = opts[:file] if opts[:file]

        cf = @cache.cache(
          path,version,user,priority,tag,fetcher.size,
          fpath,fchecksum,fmtime
        ) do |file,op|
          # Duplicate files in the cache
          if !@cache.tagfiles and File.exists?(file)
            error(errno,"Duplicate cache entries with the name '#{File.basename(path)}'")
          end
          # The file isnt in the cache, grab it
          @output.verbosel(3, "Grab the #{tag} file #{path}")
          fetcher.grab(file,@cache.directory)
          op[:mode] = @mode
          op[:norename] = (!opts[:file].nil? and !opts[:file].empty?)
        end
        cf.acquire
        @files << cf

        if checksum and !checksum.empty? \
          and !fetcher.uptodate?(checksum,cf.mtime.to_i)
        then
          error(errno,"Checksum of the file '#{path}' does not match "\
            "(an update is necessary)")
        end
      rescue Exception => e
        clean()
        raise e
      end
      cf
    end

    def self.grab(gfm,context,path,prio,tag,errno,opts={})
      file = nil
      begin
        return if !path or path.empty?
        version,user = nil
        if opts[:env] and opts[:env].recorded?
          #version = "#{opts[:env].name}/#{opts[:env].version.to_s}"
          version = 'env'
          user = opts[:env].user
        elsif prio != :anon
          version = 'file'
        else
          version = context[:deploy_id].to_s
          opts[:md5] = nil
        end

        user = context[:execution].true_user unless user

        file = gfm.grab(
          path,
          version,
          user,
          Cache::PRIORITIES[prio],
          tag,
          errno,
          opts[:md5],
          opts
        )

        path.gsub!(path,file.file)
      rescue KadeployError => ke
        ke.context = context
        raise ke
      end

      file
    end

    def self.grab_user_files(context,output)
      files = []
      gfm = Managers::GrabFileManager.new(
        context[:common].cache[:global], output,
        context[:client], context[:database], 640
      )
      env = context[:execution].environment

      # Env tarball
      envprio = (env.recorded? ? :db : :anon)
      if env and tmp = env.tarball
        grab(gfm,context,tmp['file'],envprio,'tarball',
          FetchFileError::INVALID_ENVIRONMENT_TARBALL,
          :md5=>tmp['md5'], :env => env
        )
      end

      # SSH key file
      grab(gfm,context,context[:execution].key,:anon,'key',
        FetchFileError::INVALID_KEY)

      # Preinstall archive
      if env and tmp = env.preinstall
        grab(gfm,context,tmp['file'],envprio,'preinstall',
          FetchFileError::INVALID_PREINSTALL, :md5 => tmp['md5'], :env => env,
          :maxsize => context[:common].max_preinstall_size,
          :maxsize_errno => FetchFileError::PREINSTALL_TOO_BIG
        )
      end

      # Postinstall archive
      if env and env.postinstall
        env.postinstall.each do |f|
          grab(gfm,context,f['file'],envprio,'postinstall',
            FetchFileError::INVALID_POSTINSTALL, :md5 => f['md5'], :env => env,
            :maxsize => context[:common].max_postinstall_size,
            :maxsize_errno => FetchFileError::POSTINSTALL_TOO_BIG
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
                grab(gfm,context,entry[:file],:anon,'custom_file',
                  FetchFileError::INVALID_CUSTOM_FILE)
              elsif entry[:action] == :run
                grab(gfm,context,entry[:file],:anon,'custom_file',
                  FetchFileError::INVALID_CUSTOM_FILE)
              end
            end
          end
        end
      end
      files += gfm.files

      # Custom PXE files
      begin
        if context[:execution].pxe_profile_msg != ''
          unless context[:execution].pxe_upload_files.empty?
            gfmk = Managers::GrabFileManager.new(
              context[:common].cache[:netboot], output,
              context[:client], context[:database], 744
            )

            context[:execution].pxe_upload_files.each do |pxefile|
              grab(gfmk,context,pxefile,:anon,'pxe',
                FetchFileError::INVALID_PXE_FILE,
                :file => File.join(context[:common].cache[:netboot].directory,
                  (
                    NetBoot.custom_prefix(
                      context[:execution].true_user,
                      context[:deploy_id]
                    ) + '--' + File.basename(pxefile)
                  )
                )
              )
            end
            files += gfmk.files
          end
        end
      rescue Exception => e
        gfm.clean
        raise e
      end

      files
    end
  end
end

