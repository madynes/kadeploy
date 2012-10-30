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

class CacheFile
  MODE=0640
  FSEP_VALUE='%'
  FSEP_AFFECT='='

  attr_reader :file, :user, :priority, :path , :md5, :size, :atime, :mtime, :lock, :filename

  def initialize(file,path,prefix,user,priority,tag='')
    file = self.class.absolute_path(file)

    self.class.readable?(file)

    @file = file
    @path = path
    @prefix = prefix
    @priority = priority
    @user = user
    @tag = tag
    @lock = Mutex.new

    refresh()
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
    @mtime = File.mtime(@file)
    @atime = Time.now
    @md5 = MD5::get_md5_sum(@file)
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
      update_mtime() if @mtime.nil?
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
  PRIORITIES = {
    :anon => 1,
    :db => 2,
  }

  attr_reader :files

  # !!! maxsize in Bytes
  def initialize(directory, maxsize, idxmeth, prefix_base = PREFIX_BASE)
    directory = CacheFile.absolute_path(directory)
    raise KadeployError.new(FetchFileError::CACHE_INTERNAL_ERROR,nil,"#{directory} is not a directory") unless File.directory?(directory)
    raise KadeployError.new(FetchFileError::CACHE_INTERNAL_ERROR,nil,"Invalid cache size '#{maxsize}'") unless maxsize.is_a?(Fixnum) and maxsize > 0

    @directory = directory
    @cursize = 0 # Bytes
    @maxsize = maxsize # TODO: in Bytes
    @prefix_base = prefix_base
    @files = {}
    @idxc = idxmeth #TODO: check that class exists
    @lock = Mutex.new
    load()
  end

  def hit?(params={}) #user,basename,mtime,md5
    (get(params) != nil)
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
      :file => file,
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
        raise KadeployError.new(FetchFileError::FILE_TOO_BIG,nil,"Impossible to cache the file '#{file}', the file is too big")
      end
    end
    ret
  end

  # Cache a file and get a path to the cached version
  def cache(file,path,user,md5,mtime,priority,tag='')
    if ret = read({
      :file => file,
      :path => path,
      :user => user,
      :md5 => md5,
      :mtime => mtime,
      :priority => priority,
      :tag => tag,
    }) then
      save = false
      if mtime > ret.mtime and md5.call != ret.md5
      # The file has changed
        new = CacheFile.new(
          file,
          path,
          @prefix_base,
          user,
          priority,
          tag
        )
        @lock.synchronize do
          # It is replaced by the new version
          delete!(ret)
          unless ret = add!(new)
            raise KadeployError.new(FetchFileError::FILE_TOO_BIG,nil,"Impossible to cache the file '#{file}', the file is too big")
          end
        end
        save = true
      else
        # Update file proprieties if they has changed
        save = ret.update(
          :priority => (priority > ret.priority ? priority : nil),
          :user => user,
          :tag => tag
        )
      end
      ret.save(@directory) if save
    else
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
    return true if amount < freesize!()
    cleanables!().each do |file|
#puts "CLEANABLE: #{file.filename} #{file.atime}"
      return true if amount < freesize!()
      delete!(file)
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

  # Return an array of cleanable CacheFiles sorted by priority and atime
  def cleanables()
    @lock.synchronize{ cleanables!() }
  end

  # !!! Be careful, use lock
  def cleanables!()
    @files.values.select{ |v| !v.lock.locked? }.sort_by{ |v| "#{v.priority}#{v.atime.to_i}".to_i }
  end

  # Clean every cache values that are freeable and have a priority lesser than max_priority
  def clean(max_priority)
    cleanables!().select{ |v| v.priority < max_priority }.each do |file|
      delete(file)
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
