# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Ruby libs
require 'pathname'
require 'thread'
require 'fileutils'
require 'digest'
require 'base64'
require 'uri'
#require 'ftools'

#Kadeploy3 libs
require 'error'
require 'md5'
require 'execute'

module Base64
  def self.regexp
    /((?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?)/
  end

  def self.strict_encode64(bin)
    encode64(bin).gsub!("\n",'')
  end
end

class CacheIndexPVHash
  def self.idx(params)
    return Digest.hexencode("#{params[:version].to_s}/#{params[:path]}").to_i(16)
  end
end

class CacheFile
  MODE=0640
  FSEP_VALUE='%'
  FSEP_AFFECT='='

  attr_reader :file, :user, :priority, :path , :version, :tag, :md5, :size, :atime, :mtime, :lock, :refs, :filename

  def initialize(file,path,version,prefix,user,priority,tag='')
    file = self.class.absolute_path(file)

    self.class.readable?(file)

    @file = file.clone # The file in the filesystem
    @path = path.clone # The path where the file is coming from (URL,...)
    @version = version.clone # The version of the file
    @prefix = prefix.clone
    @priority = priority
    @md5 = '' if @priority == 0 # No md5 checking for single usage files
    @user = user.clone
    @tag = tag.clone
    @lock = Mutex.new
    @refs = 0

    refresh()
  end

  def used?
    (@refs > 0)
  end

  def acquire
    @refs += 1
  end

  def release
    @refs -= 1 if @refs > 0
  end

  def idx(idxc)
    @lock.synchronize{ idx!(idxc) }
  end

  def idx!(idxc)
    idxc.idx(to_hash!())
  end

  def to_hash()
    @lock.synchronize{ to_hash!() }
  end

  def to_hash!()
    ret = {}
    instance_variables.each do |instvar|
      ret[instvar[1..-1].to_sym] = instance_variable_get(instvar)
    end
    ret
  end

  # The file descirbed in @path is a local file (in the filesystem)
  def local?()
    self.class.local_path(@path)
  end

  def update(changes)
    @lock.synchronize{ update!(changes) }
  end

  def update_atime()
    @atime = Time.now
    self
  end

  def update_mtime()
    Execute["touch -m #{@file}"].run!.wait
    @mtime = File.mtime(@file)
    self
  end

  def save(directory,opts={})
    @lock.synchronize{ save!(directory,opts) }
  end

  # !!! Be careful, use lock
  def save!(directory,opts={})
    if !opts[:norename] and @filename != File.basename(@file)
      directory = CacheFile.absolute_path(directory)
      raise KadeployError.new(FetchFileError::CACHE_INTERNAL_ERROR,nil,
        "Cant save cache file '#{@filename}'") unless File.directory?(directory)

      filename = File.join(directory,@filename)
      Execute["mv #{@file} #{filename}"].run!.wait
      @file = filename
    end
    update_mtime() if @mtime.nil? #and local_path?()
    update_atime() if @atime.nil?
    Execute["chmod #{opts[:mode]} #{@file}"].run!.wait if opts[:mode]
    self
  end

  def remove()
    @lock.synchronize{ remove!() }
  end

  # !!! Be careful, use lock
  def remove!()
    #FileUtils.rm_f(@file)
    Execute["rm -f #{@file}"].run!.wait
    @mtime = nil
    @atime = nil
    @md5 = nil
    @filename = nil

    self
  end

  # The file is accessible in the filesystem
  def self.local_path?(pathname)
    URI.parse(pathname).scheme.nil?
  end

  def self.absolute_path(file)
    begin
      file = File.expand_path(file)
    rescue ArgumentError
      raise KadeployError.new(FetchFileError::CACHE_INTERNAL_ERROR,nil,"Invalid path '#{file}'")
    end
    file
  end

  def self.readable?(file)
    raise KadeployError.new(FetchFileError::CACHE_INTERNAL_ERROR,nil,"File '#{file}' is not readable") if !File.file?(file) or !File.readable?(file) or !File.readable_real?(file)
  end

  def self.load(file,prefix)
    file = absolute_path(file)
    readable?(file)

    self.new(
      file,
      parse_path(file,prefix),
      parse_version(file,prefix),
      prefix,
      parse_user(file,prefix),
      parse_priority(file,prefix),
      parse_tag(file,prefix)
    )
  end

  def self.genval(key,val)
    "#{FSEP_VALUE}#{key}#{FSEP_AFFECT}#{(val.is_a?(Regexp) ? val.source : val.to_s)}"
  end

  def self.filename(prefix,path,version,user,md5,priority,tag)
    "#{prefix}#{genval('u',user)}#{genval('t',tag)}#{genval('b',File.basename(path))}#{genval('f',Base64.strict_encode64(path))}#{genval('v',Base64.strict_encode64(version))}#{genval('m',md5)}#{genval('p',priority)}"
  end

  def self.regexp_filename(prefix_base)
    /^#{prefix_base}#{genval('u',/(.+)/)}#{genval('t',/(.*)/)}#{genval('b',/(.+)/)}#{genval('f',Base64.regexp)}#{genval('v',Base64.regexp)}#{genval('m',/([0-9a-fA-F]*)/)}#{genval('p',/(\d+)/)}$/
  end

  # Not used in Kadeploy atm
  def update!(changes)
    filename = @filename
    @priority = changes[:priority] if changes[:priority] and changes[:priority] != @priority
    @user = changes[:user] if changes[:user] and changes[:user] != @user
    @tag = changes[:tag] if changes[:tag] and changes[:tag] != @tag
    @filename = self.class.filename(@prefix,@path,@version,@user,@md5,@priority,@tag)
    (filename != @filename)
  end

  # Not used in Kadeploy atm
  def refresh()
    @lock.synchronize{ refresh!() }
  end

  # Not used in Kadeploy atm
  # !!! Be careful, use lock
  def refresh!()
    @mtime = File.mtime(@file) #if local_path?()
    @atime = Time.now
    @md5 = MD5::get_md5_sum(@file) if @priority != 0
    @size = File.size(@file)
    @filename = self.class.filename(@prefix,@path,@version,@user,@md5,@priority,@tag)
  end

  # Not used in Kadeploy atm
  def replace(newfile,idxc)
    @lock.synchronize{ replace!(newfile,idxc) }
  end

  # Not used in Kadeploy atm
  def replace!(newfile,idxc)
    if newfile.filename != @filename
      remove!() #if idx(idxc) != newfile.idx(idxc)
      @file = newfile.file
      update!(newfile.to_hash)
      refresh!()
      @mtime = nil
    end
    self
  end

  protected

  def self.parse_priority(file,prefix)
    filename = File.basename(file)
    if filename =~ regexp_filename(prefix)
      Regexp.last_match(7).to_i
    else
      nil
    end
  end

  def self.parse_user(file,prefix)
    filename = File.basename(file)
    if filename =~ regexp_filename(prefix)
      Regexp.last_match(1)
    else
      nil
    end
  end

  def self.parse_tag(file,prefix)
    filename = File.basename(file)
    if filename =~ regexp_filename(prefix)
      Regexp.last_match(2)
    else
      nil
    end
  end

  def self.parse_path(file,prefix)
    filename = File.basename(file)
    if filename =~ regexp_filename(prefix)
      Base64.decode64(Regexp.last_match(4))
    else
      nil
    end
  end

  def self.parse_version(file,prefix)
    filename = File.basename(file)
    if filename =~ regexp_filename(prefix)
      Base64.decode64(Regexp.last_match(5))
    else
      nil
    end
  end
end

class Cache
  PREFIX_BASE = 'KACACHE'
  # Be careful, elements with priority 0 are deleted in block if possible -> adapted for elements cached for a single usage
  PRIORITIES = {
    :anon => 0,
    :db => 1,
  }

  attr_reader :files, :directory, :maxsize, :tagfiles

  # Tagfiles: rename cached files and move them to the cache directory in order to be able to reload on relaunch, when files are not tagged, the directory is fully cleaned on loading
  # !!! maxsize in Bytes
  def initialize(directory, maxsize, idxmeth, tagfiles, prefix_base=PREFIX_BASE)
    directory = CacheFile.absolute_path(directory)
    raise KadeployError.new(FetchFileError::CACHE_INTERNAL_ERROR,nil,"#{directory} is not a directory") unless File.directory?(directory)
    raise KadeployError.new(FetchFileError::CACHE_INTERNAL_ERROR,nil,"Invalid cache size '#{maxsize}'") unless maxsize.is_a?(Fixnum) and maxsize > 0

    @directory = directory
    @cursize = 0 # Bytes
    @maxsize = maxsize # Bytes
    @prefix_base = prefix_base
    @tagfiles = tagfiles
    @files = {}
    @idxc = idxmeth #TODO: check that class exists
    @lock = Mutex.new
    load()
  end

  def debug(msg)
    puts msg
  end

  def hit?(params={}) #user,basename,mtime,md5
    @lock.synchronize{ (get(params) != nil) }
  end

  def read(params={})
    if ret = get(params)
      ret.update_atime
    end
    ret
  end

  def write(path,version,user,priority,tag='',size=nil,fpath=nil)
    ret = nil
    unless get({
      :path => path,
      :version => version,
      :user => user,
      :priority => priority,
      :tag => tag,
    }) then
      # If new version have a greater priority (less chances to be deleted), change it: f.save if f.update(:priority => priority) if priority > f.priority
      tmp = nil
      begin
        # If a size was given, clean the cache before grabbing the new file
        @lock.lock
        freesize = freesize!()
        if size and size > freesize
          if size > (freeable!() + freesize)
            @lock.unlock
            raise KadeployError.new(
              FetchFileError::CACHE_FULL,nil,
              "Impossible to cache the file '#{path}', the cache is full"
            )
          else
            unless free!(size)
              @lock.unlock
              raise KadeployError.new(
                FetchFileError::CACHE_FULL,nil,
                "Impossible to cache the file '#{path}', the cache is full"
              )
            end
          end
        end
        @lock.unlock

        if fpath
          file = fpath
        else
          begin
            tmp = Tempfile.new('FETCH',@directory)
            file = tmp.path
          rescue
            raise KadeployError.new(
              FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE,nil,
              "Tempfiles cannot be created"
            )
          end
        end

        opts = {}
        yield(file,opts)
        tmp.close if tmp
        opts[:norename] = true if !@tagfiles

        if ret = add(CacheFile.new(file,path,version,@prefix_base,user,priority,tag))
          ret.save(@directory,opts)
        else
          raise KadeployError.new(
            FetchFileError::CACHE_FULL,nil,
            "Impossible to cache the file '#{path}', the cache is full"
          )
        end
      ensure
        tmp.unlink if tmp
      end
    end
    ret
  end

  # Cache a file and get a path to the cached version
  # Be careful, files of priority 0 are deleted in block (adapted for files that are cached for a single use)
  # The greater the priority is, the later the file will be deleted (TODO: translate this sentence in english :))
  # If a block is given it will be used to grab 'file' before add it to the cache
  def cache(path,version,user,priority,tag='',size=nil,file=nil,md5=nil,mtime=nil,&block)
    tmp = nil
    if ret = read({
      :path => path,
      :version => version,
      :user => user,
      :priority => priority,
      :tag => tag,
    }) then
      if ((mtime and mtime.call > ret.mtime) or !mtime) \
        and (md5 and md5.call != ret.md5)
      then
        # The file has changed
        if ret.used?
          raise KadeployError.new(FetchFileError::INVALID_MD5,nil,
            "The checksum of the (used) file '#{file}' does not match"
          )
        else
          delete(ret)
          ret = write(path,version,user,priority,tag,size,file) do |f,o|
            yield(f,o)
          end
        end
      end
    else
      ret = write(path,version,user,priority,tag,size,file) do |f,o|
        yield(f,o)
      end
    end
    ret
  end

  # Free (at least) a specific amout of memory in the cache
  def free(amount=0)
    @lock.synchronize{ free!(amount) }
  end

  # !!! Be careful, use lock
  def free!(amount=0)
    amount = @maxsize if amount == 0
    #return true if amount < freesize!()

    # Delete all elements with prio 0 (elements in cache for a single usage)
    clean!(0)

    return true if amount < freesize!()

    # Delete elements depending on their priority and last access time
    # (Do not use cleanables() since there is too much race conditions)
    @files.values.sort_by{|v| "#{v.priority}#{v.atime.to_i}".to_i}.each do |file|
      return true if amount < freesize!()
      delete!(file) unless file.used?
    end

    return amount < freesize!()
  end

  def freeable()
    @lock.synchronize{ freeable!() }
  end

  def freeable!()
    size = 0
    @files.each_value do |file|
      size += file.size unless file.used?
    end
    size
  end

  def freesize()
    @lock.synchronize{ freesize!() }
  end

  # !!! Be careful, use lock
  def freesize!()
    @maxsize - @cursize
  end

  # Clean every cache values that are freeable and have a priority lesser or equal to max_priority
  def clean(max_priority=0)
    @lock.synchronize{ clean!(max_priority) }
  end

  # !!! Be careful, use lock
  def clean!(max_priority=0)
    @files.values.each do |file|
      delete!(file) if file.priority <= max_priority and !file.used?
    end
  end

  def load()
    debug("Loading cache #{@directory} ...")
    exclude = [ '.', '..' ]
    files = []
    Dir.entries(@directory).sort.each do |file|
      rfile = File.join(@directory,file)
      if !exclude.include?(file)
        if @tagfiles
          if File.file?(rfile) \
            and file =~ CacheFile.regexp_filename(@prefix_base) \
          then
            files << CacheFile.load(rfile,@prefix_base)
          end
        else
          # Remove every files from directory if file not tagged
          debug("Delete file #{rfile} from cache")
          #FileUtils.rm_f(rfile)
          Execute["rm -f #{rfile}"].run!.wait
        end
      end
    end

    # Only keep the most recently used files with the greater priority
    @lock.lock
    if @tagfiles
      files.sort_by{|v| "#{v.priority}#{v.atime.to_i}".to_i}.reverse!.each do |file|
        if file.priority != 0 and file.size <= freesize!()
          if cfile = add!(file)
            debug("Load cached file #{file.path} (#{cfile.size/(1024*1024)}MB)")
            cfile.save(@directory)
          else
            debug("Delete cached file #{file.path} from cache "\
              "(#{file.size/(1024*1024)}MB)")
            #FileUtils.rm_f(rfile)
            Execute["rm -f #{file.file}"].run!.wait
          end
        else
          debug("Delete cached file #{file.path} from cache "\
            "(#{file.size/(1024*1024)}MB)")
          #FileUtils.rm_f(rfile)
          Execute["rm -f #{file.file}"].run!.wait
        end
      end
    end
    @lock.unlock
    debug("Cache #{@directory} loaded (#{@cursize/(1024*1024)}MB)")
  end

  protected

  def get(params={})
    @lock.synchronize{ get!(params) }
  end

  def get!(params={})
    @files[@idxc.idx(params)]
  end

  def add(file)
    @lock.synchronize{ add!(file) }
  end

  # !!! Be careful, use lock
  def add!(file)
    return nil if file.size > @maxsize
    if file.size > freesize!()
      return nil unless free!(file.size)
    end
    idx = file.idx(@idxc)

    if @files[idx]
      @files[idx].replace(file,@idxc)
    else
      @files[idx] = file
    end

    @cursize += file.size

    @files[idx]
  end

  def delete(file)
    @lock.synchronize{ delete!(file) }
  end

  def delete!(file)
    idx = file.idx(@idxc)
    @cursize -= @files[idx].remove().size
    @files.delete(idx)
  end
end
