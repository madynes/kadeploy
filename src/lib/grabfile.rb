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
require 'fetchfile'

#Ruby libs
require 'thread'
require 'uri'
require 'fileutils'
require 'tempfile'

class GrabFile
  include Printer

  @config = nil
  @files = nil
  attr_accessor :files
  attr_reader :output

  def initialize(cache, output, mode=0640, client = nil)
    @cache = cache
    @output = output
    @mode = mode
    @client = client
    @files = []
  end

  def error(errno,msg)
    clean()
    raise KadeployError.new(errno,nil,msg)
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
      fetcher = FetchFile[path,errno,@client]

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

      fmtime, fchecksum, fpath = nil
      if opts[:file]
        #error(errno,"The #{tag} file '#{path}' must be local") \
        #  unless fetcher.is_a?(LocalFetch)
        fmtime = lambda{ fetcher.mtime }
        fchecksum = lambda{ fetcher.checksum }
        fpath = opts[:file]
      end

      cf = @cache.cache(
        path,version,user,priority,tag,fetcher.size,
        fpath,fchecksum,fmtime
      ) do |file,op|
        # Duplicate files in the cache
        if !@cache.tagfiles and File.exists?(file)
          error(errno,"Duplicate cache entries with the name '#{File.basename(path)}'")
        end
        # The file isnt in the cache, grab it
        debug(3, "Grab the #{tag} file #{path}")
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
        version = context[:wid].to_s
        opts[:md5] = nil
      end

      user = context[:execution].user unless user

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

  def self.grab_user_files(context)
    files = []

    cexec = context[:execution]

    gfm = self.new(
      context[:common].cache[:global], context[:output], 640, cexec.client
    )

    env = cexec.environment

    # Env tarball
    envprio = (env.recorded? ? :db : :anon)
    if env and tmp = env.tarball
      grab(gfm,context,tmp['file'],envprio,'tarball',
        FetchFileError::INVALID_ENVIRONMENT_TARBALL,
        :md5=>tmp['md5'], :env => env
      )
    end

    # SSH key file
    grab(gfm,context,cexec.key,:anon,'key',FetchFileError::INVALID_KEY)

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
    if cexec.custom_operations
      cexec.custom_operations.each_pair do |macro,micros|
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
      if cexec.pxe_profile_msg and !cexec.pxe_upload_files.empty?
        gfmk = self.new(context[:common].cache[:netboot], context[:output],
          744, cexec.client)

        cexec.pxe_upload_files.each do |pxefile|
          grab(gfmk,context,pxefile,:anon,'pxe',
            FetchFileError::INVALID_PXE_FILE,
            :file => File.join(context[:common].cache[:netboot].directory,
              (
                NetBoot.custom_prefix(
                  cexec.user,
                  context[:wid]
                ) + '--' + File.basename(pxefile)
              )
            )
          )
        end
        files += gfmk.files
      end
    rescue Exception => e
      gfm.clean
      raise e
    end

    files
  end
end

