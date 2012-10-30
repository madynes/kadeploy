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
require 'fileutils'
require 'tempfile'

module Managers
  class Fetch
    def initialize(path,client)
      @path = path
      @client = client
    end

    def error(errno,msg)
      @client.print("Error: #{msg}")
      raise KadeployError.new(errno,nil,msg)
    end

    def size
    end

    def checksum
    end

    def mtime
    end

    def grab(dest,errno,dir=nil)
    end

    def uptodate?(fchecksum,fmtime=nil)
    end
  end

  class LocalFetch < Fetch
    def size
      if File.readable?(@path)
        File.size(@path)
      else
        @client.get_file_size(@path)
      end
    end

    def checksum
      if File.readable?(@path)
        MD5::get_md5_sum(@path)
      else
        @client.get_file_md5(@path)
      end
    end

    def mtime
      if File.readable?(@path)
        File.mtime(@path).to_i
      else
        @client.get_file_mtime(@path)
      end
    end

    def grab(dest,errno,dir=nil)
      if File.readable?(@path)
        begin
          FileUtils.cp(@path,dest)
        rescue => e
          error(errno,"Unable to grab the file #{@path}")
        end
      else
        begin
          @client.get_file(@path,dest)
        rescue
          error(errno,"Unable to grab the file #{@path}")
        end
      end
    end

    def uptodate?(fchecksum,fmtime=nil)
      !((mtime > fmtime) and (checksum != fchecksum))
    end
  end

  class HTTPFetch < Fetch
    def initialize(path,client)
      super(path,client)
    end

    def size
      HTTP::get_file_size(@path)
    end

    def checksum
      resp, etag = HTTP.check_file(@path)
      case resp
      when 200,304
      else
        error(errno,"Unable to grab the file #{@path} (http error ##{resp})")
      end
      etag
    end

    def mtime
      nil
    end

    def grab(dest,errno,dir=nil)
      resp, etag = HTTP.fetch_file(
        @path,dest,dir,nil
      )
      case resp
      when -1
        error(FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE,
          "Tempfiles cannot be created")
      when -2
        error(FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE,
          "Environment file cannot be moved")
      when 200
      else
        error(errno,"Unable to grab the file #{@path} (http error ##{resp})")
      end
    end

    def uptodate?(fchecksum,fmtime=nil)
      (checksum == fchecksum)
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

    # Constructor of GrabFileManager
    #
    # Arguments
    # * config: instance of Config
    # * output: instance of OutputControl
    # * client : Drb handler of the client
    # * db: database handler
    # Output
    # * nothing
    def initialize(cache, output, client, db, mode=0640)
      @cache = cache
      @output = output
      @client = client
      @db = db
      @mode = mode
      @files = []
    end

    def error(errno,msg)
      @output.verbosel(0, "Error: #{msg}")
      clean()
      raise KadeployError.new(errno,nil,msg)
    end

    def debug(msg)
      @output.verbosel(0, "Warning: #{msg}")
    end

    def clean()
      @files.each do |file|
        @cache.delete(file)
      end
    end
=begin
    def fetch_local(path,dest,errno,expected_md5)
      mtime,md5 = nil
      if File.readable?(path)
        if File.size(path) > @cache.maxsize
          error(FetchFileError::FILE_TOO_BIG,
            "Impossible to cache the file '#{path}', the file is too big")
        end
        mtime = lambda { File.mtime(path).to_i }
        md5 = lambda { MD5::get_md5_sum(path) }
        begin
          FileUtils.cp(path,dest)
        rescue => e
          error(errno,"Unable to grab the file #{path}")
        end
      else
        if @client.get_file_size(path) > @cache.maxsize
          error(FetchFileError::FILE_TOO_BIG,
            "Impossible to cache the file '#{path}', the file is too big")
        end
        mtime = lambda { @client.get_file_mtime(path) }
        md5 = lambda { @client.get_file_md5(path) }
        begin
          @client.get_file(path,dest)
        rescue
          error(errno,"Unable to grab the file #{path}")
        end
      end
      [mtime,md5]
    end

    def fetch_http(url,dest,errno,expected_md5)
      size = HTTP::get_file_size(url)
      if size > @cache.maxsize
        error(FetchFileError::FILE_TOO_BIG,
          "Impossible to cache the file '#{url}', the file is too big")
      end

      resp, etag = HTTP.fetch_file(
        url,dest,@cache.directory,nil
      )
      case resp
      when -1
        error(TEMPFILE_CANNOT_BE_CREATED_IN_CACHE,"Tempfiles cannot be created")
      when -2
        error(FILE_CANNOT_BE_MOVED_IN_CACHE,"Environment file cannot be moved")
      else
        error(errno,"Unable to grab the file #{url} (http error ##{resp})")
      end
#=begin
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
#=end
      [lambda{etag.gsub("\"","")},nil]
    end
    alias :fetch_https :fetch_http
=end

    # ajout, path/version
    def grab_file(path,user,priority,tag,errno,checksum=nil,env=nil)
      cf = nil
      begin
        fetcher = nil
        kind = URI.parse(path).scheme || 'local'
        case kind
        when 'local'
          fetcher = LocalFetch.new(path,@client)
        when 'http','https'
          fetcher = HTTPFetch.new(path,@client)
        end

        if fetcher.size > @cache.maxsize
          error(FetchFileError::FILE_TOO_BIG,
            "Impossible to cache the file '#{path}', the file is too big")
        end

        cf = @cache.cache(path,user,priority,tag) do |file|
          # The file isnt in the cache, grab it
          @output.verbosel(3, "Grab the #{kind} #{tag} file #{path}")
          fetcher.grab(file,errno,@cache.directory)
          FileUtils.chmod(@mode,file)
        end
        @files << cf

        if checksum and !fetcher.empty? and !fetcher.uptodate?(checksum,cf.mtime)
          error(errno,"Checksum of the file '#{path}' does not match "\
            "(please update or create a new version of your environment)")
        end

        # Update md5 for HTTP env
        if ['http','https'].include?(kind) and env and env.recorded?
          env.set_md5(file.tag, file.path, fetcher.checksum, @db)
        end
      rescue Exception => e
        clean()
        raise e
      end
      cf
    end

    def self.grab(gfm,context,path,prio,tag,errno,opts={})
      file = gfm.grab_file(
        path,
        context[:execution].true_user,
        Cache::PRIORITIES[prio],
        tag,
        errno,
        opts[:md5],
        opts[:env]
      )

      # TODO: in bytes
      if opts[:maxsize] and (file.size > opts[:maxsize])
        gfm.error(opts[:maxsize_errno],
          "The #{file.tag} file '#{file.path}' is too big "\
          "(#{opts[:maxsize]} MB is the max size)"
        )
      end

      path.gsub!(path,file.file) unless opts[:noaffect]

      file
    end

    def self.grab_user_files(context,output)
      gfm = Managers::GrabFileManager.new(
        context[:common].cache[:global], output,
        context[:client], context[:database], 0640
      )
      env = context[:execution].environment

#context[:deploy_id]
      # Env tarball
      if tmp = env.tarball
        grab(gfm,context,tmp['file'],:db,'tarball',
          FetchFileError::INVALID_ENVIRONMENT_TARBALL,
          :md5=>tmp['md5'], :env => env
        )
      end

      # SSH key file
      grab(gfm,context,context[:execution].key,:anon,'key',
        FetchFileError::INVALID_KEY)

      # Preinstall archive
      if tmp = env.preinstall
        grab(gfm,context,tmp['file'],:db,'preinstall',
          FetchFileError::INVALID_PREINSTALL, :md5 => tmp['md5'], :env => env,
          :maxsize => context[:common].max_preinstall_size,
          :maxsize_errno => FetchFileError::PREINSTALL_TOO_BIG
        )
      end

      # Postinstall archive
      if env.postinstall
        env.postinstall.each do |f|
          grab(gfm,context,f['file'],:db,'postinstall',
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

      gfmk = Managers::GrabFileManager.new(
        context[:common].cache[:netboot], output,
        context[:client], context[:database], 0744
      )

      # Custom PXE files
      begin
        if context[:execution].pxe_profile_msg != ''
          unless context[:execution].pxe_upload_files.empty?
            context[:execution].pxe_upload_files.each do |pxefile|
              grab(gfm,context,pxefile,:anon,'pxe_file',
                FetchFileError::INVALID_PXE_FILE, :noaffect => true)
            end
          end
        end
      rescue Exception => e
        gfm.clean
        raise e
      end

      gfm.files += gfmk.files
    end
  end
end

