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

class CacheIndexPHash
  def self.idx(params)
    return Digest.hexencode(params[:path]).to_i(16)
  end
end

class CacheLock
  def initialize()
    @locked = false
  end

  def lock
    @locked = true
  end

  def unlock
    @locked = false
  end

  def locked?
    @locked
  end

  def synchronize(&block)
    sleep(0.2) until !locked?
    lock()
    ret = yield
    unlock()
    ret
  end
end

class CacheRefs
  attr_reader :refs

  def initialize()
    @refs = 0
  end

  def acquire
    @refs += 1
  end

  def release
    @refs -= 1 if @refs > 0
  end
end

class CacheFile
  MODE=0640
  FSEP_VALUE='%'
  FSEP_AFFECT='='

  attr_reader :file, :user, :priority, :path , :tag, :md5, :size, :atime, :mtime, :lock, :refs, :filename

  def initialize(file,path,prefix,user,priority,tag='')
    file = self.class.absolute_path(file)

    self.class.readable?(file)

    @file = file.clone # The file in the filesystem
    @path = path.clone # The path where the file is coming from (URL,...)
    @prefix = prefix.clone
    @priority = priority
    @md5 = '' if @priority == 0 # No md5 checking for single usage files
    @user = user.clone
    @tag = tag.clone
    @lock = CacheLock.new
    @refs = CacheRefs.new

    refresh()
  end

  def used?
    (@refs.refs > 0)
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

  def info()
    @lock.synchronize{ info!() }
  end

  def info!()
    to_hash!()
  end

  def update(changes)
    @lock.synchronize{ update!(changes) }
  end

  def update!(changes)
    filename = @filename
    @priority = changes[:priority] if changes[:priority] and changes[:priority] != @priority
    @user = changes[:user] if changes[:user] and changes[:user] != @user
    @tag = changes[:tag] if changes[:tag] and changes[:tag] != @tag
    @filename = self.class.filename(@prefix,@path,@user,@md5,@priority,@tag)
    (filename != @filename)
  end

  def refresh()
    @lock.synchronize{ refresh!() }
  end

  # !!! Be careful, use lock
  def refresh!()
    @mtime = File.mtime(@file) #if local_path?()
    @atime = Time.now
    @md5 = MD5::get_md5_sum(@file) if @priority != 0
    @size = File.size(@file)
    @filename = self.class.filename(@prefix,@path,@user,@md5,@priority,@tag)
  end

  def update_atime()
    @atime = Time.now
    self
  end

  def update_mtime()
    Execute["touch -m #{@file}"].run!
    @mtime = File.atime(@file)
    self
  end

  def save(directory)
    @lock.synchronize{ save!(directory) }
  end

  # !!! Be careful, use lock
  def save!(directory)
    if @filename != File.basename(@file)
      directory = CacheFile.absolute_path(directory)
      raise KadeployError.new(FetchFileError::CACHE_INTERNAL_ERROR,nil,"Cant save cache file '#{@filename}'") unless File.directory?(directory)

#puts "mv #{@file} #{File.join(directory,@filename)}"
      FileUtils.mv(@file,File.join(directory,@filename))
      @file = File.join(directory,@filename)
      FileUtils.chmod(MODE,@file)
      update_mtime() if @mtime.nil? #and local_path?()
      update_atime() if @atime.nil?
    end
    self
  end

  def replace(newfile,idxc)
    @lock.synchronize{ replace!(newfile,idxc) }
  end

  def replace!(newfile,idxc)
    if newfile.filename != @filename
#puts 'replace'
      remove!() #if idx(idxc) != newfile.idx(idxc)
      @file = newfile.file
      update!(newfile.to_hash)
      refresh!()
      @mtime = nil
    end
    self
  end

  def remove()
    @lock.synchronize{ remove!() }
  end

  # !!! Be careful, use lock
  def remove!()
#puts "rm -f #{@file}"
    FileUtils.rm_f(@file)
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
      prefix,
      parse_user(file,prefix),
      parse_priority(file,prefix),
      parse_tag(file,prefix)
    )
  end

  def self.genval(key,val)
    "#{FSEP_VALUE}#{key}#{FSEP_AFFECT}#{(val.is_a?(Regexp) ? val.source : val.to_s)}"
  end

  def self.filename(prefix,path,user,md5,priority,tag)
    "#{prefix}#{genval('p',priority)}#{genval('u',user)}#{genval('f',Base64.strict_encode64(path))}#{genval('m',md5)}#{genval('t',tag)}#{genval('b',File.basename(path))}"
  end

  def self.regexp_filename(prefix_base)
    /^#{prefix_base}#{genval('p',/(\d+)/)}#{genval('u',/(.+)/)}#{genval('f',Base64.regexp)}#{genval('m',/([0-9a-fA-F]+)/)}#{genval('t',/(.*)/)}#{genval('b',/(.+)/)}$/
  end

  protected

  def self.parse_priority(file,prefix)
    filename = File.basename(file)
    if filename =~ regexp_filename(prefix)
      Regexp.last_match(1).to_i
    else
      nil
    end
  end

  def self.parse_user(file,prefix)
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
      Base64.decode64(Regexp.last_match(3))
    else
      nil
    end
  end

  def self.parse_tag(file,prefix)
    filename = File.basename(file)
    if filename =~ regexp_filename(prefix)
      Regexp.last_match(5)
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

  attr_reader :files, :directory, :maxsize

  # !!! maxsize in Bytes
  def initialize(directory, maxsize, idxmeth, prefix_base = PREFIX_BASE)
    directory = CacheFile.absolute_path(directory)
    raise KadeployError.new(FetchFileError::CACHE_INTERNAL_ERROR,nil,"#{directory} is not a directory") unless File.directory?(directory)
    raise KadeployError.new(FetchFileError::CACHE_INTERNAL_ERROR,nil,"Invalid cache size '#{maxsize}'") unless maxsize.is_a?(Fixnum) and maxsize > 0

    @directory = directory
    @cursize = 0 # Bytes
    @maxsize = maxsize # Bytes
    @prefix_base = prefix_base
    @files = {}
    @idxc = idxmeth #TODO: check that class exists
    @lock = Mutex.new
    load()
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

  def write(file,path,user,priority,tag='') #md5?
    ret = nil
    unless get({
      #:file => file,
      :path => path,
      :user => user,
      :priority => priority,
      :tag => tag,
    }) then
      # If new version have a greater priority (less chances to be deleted),
      # change it
      #if priority > f.priority
      #  f.save if f.update(:priority => priority)
      #end
      #@files[idx].update_atime
      #else
      if ret = add(CacheFile.new(file,path,@prefix_base,user,priority,tag))
        ret.save(@directory)
      else
        delete(file)
        raise KadeployError.new(
          FetchFileError::FILE_TOO_BIG,nil,
          "Impossible to cache the file '#{file}', the file is too big"
        )
      end
    end
    ret
  end

  # Cache a file and get a path to the cached version
  # Be careful, files of priority 0 are deleted in block (adapted for files that are cached for a single use)
  # The greater the priority is, the later the file will be deleted (TODO: translate this sentence in english :))
  # If a block is given it will be used to update 'file' before add it to the cache
  def cache(path,user,priority,tag='',md5=nil,mtime=nil)
    if ret = read({
      #:file => file,
      :path => path,
      :user => user,
      #:md5 => md5,
      #:mtime => mtime,
      :priority => priority,
      :tag => tag,
    }) then
      if ((mtime and mtime.call > ret.mtime) or !mtime) \
        and (md5 and md5.call != ret.md5)
      then
        # The file has changed
        raise KadeployError.new(FetchFileError::INVALID_MD5,nil,
          "The checksum of the file '#{file}' does not match"
        )
      end
    else
      file = nil
      begin
        file = Tempfile.new('FETCH',@directory)
      rescue
        raise KadeployError.new(
          FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE,nil,
          "Tempfiles cannot be created"
        )
      end
      yield(file.path)
      file.close
      ret = write(file,path,user,priority,tag)
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
      delete!(file) unless file.lock.locked?
    end

    return amount < freesize!()
  end

  def freesize()
    @lock.synchronize{ freesize!() }
  end

  # !!! Be careful, use lock
  def freesize!()
    @maxsize - @cursize
  end

=begin
  # Race conditions

  # Return an array of cleanable CacheFiles sorted by priority and atime
  def cleanables()
    @lock.synchronize{ cleanables!() }
  end

  # !!! Be careful, use lock
  def cleanables!()
    @files.values.select{ |v| !v.lock.locked? }.sort_by{ |v| "#{v.priority}#{v.atime.to_i}".to_i }
  end
=end

  # Clean every cache values that are freeable and have a priority lesser or equal to max_priority
  def clean(max_priority=0)
    @lock.synchronize{ clean!(max_priority) }
  end

  # !!! Be careful, use lock
  def clean!(max_priority=0)
    @files.values.each do |file|
      delete!(file) if file.priority <= max_priority and !file.lock.locked?
    end
  end

  def load()
    exclude = [ '.', '..' ]
    Dir.entries(@directory).sort.each do |file|
      rfile = File.join(@directory,file)
      if !exclude.include?(file) \
        and File.file?(rfile) \
        and file =~ CacheFile.regexp_filename(@prefix_base) \
      then
        if cfile = add(CacheFile.load(rfile,@prefix_base))
#puts "load #{file}"
          cfile.save(@directory)
        else
          FileUtils.rm_f(rfile)
#puts "rm #{file}"
        end
      end
    end
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

  def include?(file)
  end

  def full?()
  end
end
