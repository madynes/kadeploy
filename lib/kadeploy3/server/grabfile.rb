require 'thread'
require 'uri'
require 'fileutils'
require 'tempfile'

module Kadeploy

class GrabFile
  include Printer

  @config = nil
  attr_accessor :files
  attr_reader :output

  def initialize(cache, files, lock, output, mode=0640, client = nil)
    @cache = cache
    @files = files
    @lock = lock
    @output = output
    @mode = mode
    @client = client
  end

  def error(errno,msg)
    # If something is going wrong, the will be cleaned by kaworkflow
    raise KadeployError.new(errno,nil,msg)
  end

  def grab(origin_uri,version,user,priority,tag,wid,checksum=nil,opts={})
    return nil if !origin_uri or origin_uri.empty?
    cf = nil
    fetcher = FetchFile[origin_uri,@client]

    unless @cache
      error(APIError::CACHE_ERROR,
        "Impossible to cache the file '#{origin_uri}', the cache is disabled")
    end

    if fetcher.size > @cache.max_size
      error(APIError::CACHE_ERROR,
        "Impossible to cache the file '#{origin_uri}', the file is too big for the cache")
    end

    if opts[:maxsize] and fetcher.size > opts[:maxsize]
      error(APIError::INVALID_FILE,
        "The #{tag} file '#{origin_uri}' is too big "\
        "(#{opts[:maxsize]/(1024*1024)} MB is the max allowed size)"
      )
    end

    fmtime = checksum ? nil : fetcher.mtime #does not use the mtime if checksum is provided
    fchecksum = checksum ? checksum : nil #use checksum if it provided.

    cf = @cache.cache(
            origin_uri,version,user,priority,tag,fetcher.size,
            wid,opts[:file],fchecksum,fmtime
            ) do |source,destination,size,md5|

      if md5 && fetcher.checksum && md5 != fetcher.checksum # fetcher provides the checksum
        error(APIError::INVALID_FILE,"Checksum of the file '#{source}' does not match "\
            "(an update is necessary)")
      end

      # The file does not in the cache, grab it
      debug(3, "Grab the #{tag} file #{source}")
      fetcher.grab(destination)

      #fetcher does not provides checksum
      if md5 && fetcher.checksum.nil? && md5 != Digest::MD5.file(destination).hexdigest!
        error(APIError::INVALID_FILE,"Checksum of the file '#{source}' does not match "\
            "(an update is necessary)")
      end
    end

    @lock.synchronize do
      @files << cf
    end

    cf
  end

  def self.grab(gfm,context,path,prio,tag,opts={})
    file = nil
    begin
      return if !path or path.empty?
      version,user = nil
      if opts[:env] and opts[:env].recorded?
        version = opts[:env].cache_version
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
        context[:wid],
        opts[:md5],
        opts
      )

      if file.is_a?(String)
        path.gsub!(path,file)
      else
        path.gsub!(path,file.file)
      end
    rescue KadeployError => ke
      ke.context = context
      raise ke
    end

    file
  end

  def self.grab_user_files(context,files,lock,kind)
    # If something is going wrong, the will be cleaned by kaworkflow
    cexec = context[:execution]

    gfm = self.new(context[:caches][:global],files[:global],lock,
      context[:output],640,cexec.client)

    env = cexec.environment
    envprio = nil
    envprio = (env.recorded? ? :db : :anon) if env

    # SSH key file
    grab(gfm,context,cexec.key,:anon,'key')

    #Grab tarball, Preinstall and Postinstall archive if only inside deploy kind
    if kind == :deploy
      # Env tarball
      if env and tmp = env.tarball
        grab(gfm,context,tmp['file'],envprio,'tarball',
          :md5=>tmp['md5'], :env => env
        )
      end

      # Preinstall archive
      if env and tmp = env.preinstall
        grab(gfm,context,tmp['file'],envprio,'preinstall',
          :md5 => tmp['md5'], :env => env,
          :maxsize => context[:common].max_preinstall_size
        )
      end

      # Postinstall archive
      if env and env.postinstall
        env.postinstall.each do |f|
          grab(gfm,context,f['file'],envprio,'postinstall',
            :md5 => f['md5'], :env => env,
            :maxsize => context[:common].max_postinstall_size
          )
        end
      end
    end

    # Custom files
    if cexec.custom_operations
      cexec.custom_operations[:operations].each_pair do |macro,micros|
        micros.each_pair do |micro,entries|
          entries.each do |entry|
            if entry[:action] == :send
              entry[:filename] = File.basename(entry[:file].dup)
              grab(gfm,context,entry[:file],:anon,'custom_file')
            elsif entry[:action] == :run
              grab(gfm,context,entry[:file],:anon,'custom_file')
            end
          end
        end
      end
    end

    # Custom PXE files
    if cexec.pxe and cexec.pxe[:profile] and cexec.pxe[:files] and !cexec.pxe[:files].empty?
      gfmk = self.new(context[:caches][:netboot],files[:netboot],lock,
        context[:output],744, cexec.client)

      cexec.pxe[:files].each do |pxefile|
        grab(gfmk,context,pxefile,:anon_keep,'pxe',
          :file => File.join(context[:caches][:netboot].directory,
            (
              NetBoot.custom_prefix(
                cexec.user
              ) + '--' + File.basename(pxefile)
            )
          )
        )
      end
    end
  end
end

end
