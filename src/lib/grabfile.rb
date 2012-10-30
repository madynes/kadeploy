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

    def fetch_local(path,errno,expected_md5)
      mtime,md5 = nil
      begin
        destfile = Tempfile.new('fetch_local',@cache.directory)
      rescue
      end

      if File.readable?(path)
        if File.size(path) > @cache.maxsize
          error(FetchFileError::FILE_TOO_BIG,
            "Impossible to cache the file '#{path}', the file is too big")
        end
        mtime = lambda { File.mtime(path).to_i }
        md5 = lambda { MD5::get_md5_sum(path) }
        begin
          FileUtils.cp(path,destfile.path)
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
          @client.get_file(path,destfile.path)
        rescue
          error(errno,"Unable to grab the file #{path}")
        end
      end
      destfile.close
      [destfile.path,mtime,md5]
    end

    def fetch_http(url,errno,expected_md5)
      size = HTTP::get_file_size(client_file)
      if size > @cache.maxsize
        error(FetchFileError::FILE_TOO_BIG,
          "Impossible to cache the file '#{url}', the file is too big")
      end

      begin
        destfile = Tempfile.new('fetch_http',@cache.directory)
      rescue
        error(TEMPFILE_CANNOT_BE_CREATED_IN_CACHE,"Tempfiles cannot be created")
      end

      resp, etag = HTTP.fetch_file(
        url,destfile.path,@cache.directory,nil
      )
      case resp
      when -1
        error(TEMPFILE_CANNOT_BE_CREATED_IN_CACHE,"Tempfiles cannot be created")
      when -2
        error(FILE_CANNOT_BE_MOVED_IN_CACHE,"Environment file cannot be moved")
      else
        error(errno,"Unable to grab the file #{url} (http error ##{resp})")
      end
=begin
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
=end
      destfile.close
      [destfile.path,etag.gsub("\"",""),nil]
    end
    alias :fetch_https :fetch_http

    def grab_file(path, user, priority, tag, errno, expected_md5=nil)
      # The file was not downloaded atm
      file,md5,mtime = nil
      kind = URI.parse(path).scheme || 'local'
      if f = @cache.read({
        :path => path,
        :user => user,
        :priority => priority,
        :tag => tag,
      }) then
        # The file is in the cache
        file = f.file
        md5 = lambda{ f.md5 }
        mtime = lambda{ f.mtime }
      else
        # The file isnt in the cache, grab it
        @output.verbosel(3, "Grab the #{kind} #{tag} file #{path}")
        file,md5,mtime = self.send("fetch_#{kind}".to_s,path,errno,expected_md5)
        FileUtils.chmod(@mode,file)
      end

      # Add or update the file in the cache
      cf = @cache.cache(file,path,user,priority,tag,md5,mtime)
      @files << cf
      cf
    end

    def self.grab(gfm,context,path,prio,tag,errno,opts={})
      file = gfm.grab_file(
        path,
        context[:execution].true_user,
        Cache::PRIORITIES[prio],
        tag,
        errno,
        opts[:md5]
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

      # Env tarball
      if tmp = context[:execution].environment.tarball
        grab(gfm,context,tmp['file'],:db,'environment',
          FetchFileError::INVALID_ENVIRONMENT_TARBALL, :md5=>tmp['md5'])
      end

      # SSH key file
      grab(gfm,context,context[:execution].key,:anon,'key',
        FetchFileError::INVALID_KEY)

      # Preinstall archive
      if tmp = context[:execution].environment.preinstall
        grab(gfm,context,tmp['file'],:db,'preinstall',
          FetchFileError::INVALID_PREINSTALL, :md5 => tmp['md5'],
          :maxsize => context[:common].max_preinstall_size,
          :maxsize_errno => FetchFileError::PREINSTALL_TOO_BIG
        )
      end

      # Postinstall archive
      if context[:execution].environment.postinstall
        context[:execution].environment.postinstall.each do |f|
          grab(gfm,context,f['file'],:db,'postinstall',
            FetchFileError::INVALID_POSTINSTALL, :md5 => f['md5'],
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

