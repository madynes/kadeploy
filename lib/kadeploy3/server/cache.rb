require 'pathname'
require 'thread'
require 'fileutils'
require 'digest'
require 'digest/md5'
require 'uri'
require 'yaml'

YAML::ENGINE.yamler = 'syck' if RUBY_VERSION >= '1.9'

module Kadeploy

class CacheIndexPVHash
  def self.idx(params)
    return Digest.hexencode("#{params[:version].to_s}/#{params[:path]}").to_i(16)
  end
end

class CacheFile
  @@id = 0

  MODE=0640
  FSEP_VALUE='%'
  FSEP_AFFECT='='
  EXT_META = '.meta'
  EXT_FILE = '.file'

  attr_reader :file, :user, :priority, :path , :version, :tag, :md5, :size, :atime, :mtime, :lock, :refs, :filename

  def initialize(file,path,version,prefix,user,priority,tag='')
    file = self.class.absolute_path(file)

    self.class.readable?(file)

    @uuid = self.class.gen_uuid()
    @file = file.clone # The file in the filesystem
    @meta = nil
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
    @lock.synchronize{ (@refs > 0) }
  end

  def acquire
    @lock.synchronize{ @refs += 1 }
  end

  def release
    @lock.synchronize{ @refs -= 1 if @refs > 0 }
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
    if !opts[:norename] and @filename != File.basename(@file,EXT_FILE)
      directory = CacheFile.absolute_path(directory)
      raise KadeployError.new(APIError::CACHE_ERROR,nil,
        "Cant save cache file '#{@filename}'") unless File.directory?(directory)

      newfile = File.join(directory,@filename) + EXT_FILE
      if @file != newfile
        Execute["mv #{@file} #{newfile}"].run!.wait
        @file = newfile
      end

      if @meta
        newmeta = File.join(directory,@filename) + EXT_META
        if @meta != newmeta
          Execute["mv #{@meta} #{newmeta}"].run!.wait
          @meta = newmeta
        end
      end
    end

    update_mtime() if @mtime.nil? #and local_path?()
    update_atime() if @atime.nil?

    @meta = File.join(directory,File.basename(@file,EXT_FILE)) + EXT_META unless @meta
    content = to_hash!()
    content.delete(:lock)
    File.open(@meta,"w") do |f|
      f.write(content.to_yaml)
    end

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
    Execute["rm -f #{@meta}"].run!.wait if @meta
    @mtime = nil
    @atime = nil
    @md5 = nil
    @filename = nil

    self
  end

  def self.gen_uuid()
    @@id += 1
    Digest::SHA1.hexdigest("#{Time.now.to_i}-#{@@id}")
  end

  # The file is accessible in the filesystem
  def self.local_path?(pathname)
    URI.parse(pathname).scheme.nil?
  end

  def self.absolute_path(file)
    begin
      file = File.expand_path(file)
    rescue ArgumentError
      raise KadeployError.new(APIError::CACHE_ERROR,nil,"Invalid path '#{file}'")
    end
    file
  end

  def self.readable?(file)
    raise KadeployError.new(APIError::CACHE_ERROR,nil,"File '#{file}' is not readable") if !File.file?(file) or !File.readable?(file) or !File.readable_real?(file)
  end

  def self.load(file,meta,prefix)
    file = absolute_path(file)
    readable?(file)
    meta = absolute_path(meta)
    readable?(meta)
    meta = YAML.load_file(meta)

    self.new(
      file,
      meta[:path],
      meta[:version],
      prefix,
      meta[:user],
      meta[:priority],
      meta[:tag]
    )
  end

  def self.genval(key,val)
    "#{FSEP_VALUE}#{key}#{FSEP_AFFECT}#{(val.is_a?(Regexp) ? val.source : val.to_s)}"
  end

  def self.filename(prefix,path,version,user,md5,priority,tag,uuid)
    "#{prefix}#{genval('u',user)}#{genval('t',tag)}#{genval('p',priority)}#{genval('i',uuid)}"
  end

  def self.regexp_filename(prefix_base,suffix)
    /^#{prefix_base}#{genval('u',/(.+)/)}#{genval('t',/(.*)/)}#{genval('p',/(\d+)/)}#{genval('i',/([0-9a-fA-F]*)/)}#{suffix}$/
  end

  # Not used in Kadeploy atm
  def update!(changes)
    filename = @filename
    @priority = changes[:priority] if changes[:priority] and changes[:priority] != @priority
    @user = changes[:user] if changes[:user] and changes[:user] != @user
    @tag = changes[:tag] if changes[:tag] and changes[:tag] != @tag
    @filename = self.class.filename(@prefix,@path,@version,@user,@md5,@priority,@tag,@uuid)
    (filename != @filename)
  end

  def refresh()
    @lock.synchronize{ refresh!() }
  end

  # !!! Be careful, use lock
  def refresh!()
    @mtime = File.mtime(@file) #if local_path?()
    @atime = Time.now
    @md5 = Digest::MD5.file(@file).hexdigest! if @priority != 0
    @size = File.size(@file)
    @filename = self.class.filename(@prefix,@path,@version,@user,@md5,@priority,@tag,@uuid)
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
  def initialize(directory, maxsize, idxmeth, tagfiles, prefix_base=PREFIX_BASE, emptycache=true)
    prefix_base=PREFIX_BASE if prefix_base.nil?
    directory = CacheFile.absolute_path(directory)
    raise KadeployError.new(APIError::CACHE_ERROR,nil,"#{directory} is not a directory") unless File.directory?(directory)
    raise KadeployError.new(APIError::CACHE_ERROR,nil,"Invalid cache size '#{maxsize}'") if !(maxsize.is_a?(Fixnum) or maxsize.is_a?(Bignum))  or maxsize <= 0

    @directory = directory
    @cursize = 0 # Bytes
    @maxsize = maxsize # Bytes
    @prefix_base = prefix_base
    @tagfiles = tagfiles
    @files = {}
    @idxc = idxmeth #TODO: check that class exists
    @lock = Mutex.new
    @locks = {}
    load(emptycache)
  end

  def debug(msg)
    puts msg
  end

  def hit?(params={}) #user,basename,mtime,md5
    @lock.synchronize{ (get(id(params)) != nil) }
  end

  # Cache a file and get a path to the cached version
  # Be careful, files of priority 0 are deleted in block (adapted for files that are cached for a single use)
  # The greater the priority is, the later the file will be deleted (TODO: translate this sentence in english :))
  # If a block is given it will be used to grab 'file' before add it to the cache
  def cache(path,version,user,priority,tag,size,file=nil,md5=nil,mtime=nil,&block)
    tag = '' unless tag
    fid = id({
      :path => path,
      :version => version,
      :user => user,
      :priority => priority,
      :tag => tag,
    })

    flock = nil
    create = false
    hit = nil
    ret = nil
    # Get a lock on the file fid
    @lock.synchronize do
      @locks[fid] = Mutex.new unless @locks[fid]
      flock = @locks[fid]
      flock.lock # Keep the global lock for the code to stay simple

      begin
        if ret = get(fid)
          ret.update_atime
          mtime = mtime.call.to_i if mtime
          if ((mtime and mtime > ret.mtime.to_i) or !mtime) \
            and (md5 and md5.call != ret.md5)
          then
            if ret.used?
              raise KadeployError.new(APIError::CACHE_ERROR,nil,
                "The checksum of the (used) file '#{path}' does not match"
              )
            else
              release(ret.size)
              delete(ret)
              create = true
              hit = false
            end
          else # The file was found in the cache
            # Hack not for the checksum to be performed in vain the next time
            ret.update_mtime if mtime and mtime > ret.mtime.to_i
          end
        else
          create = true
          hit = false
        end

        if create
          # If a size was given, clean the cache before grabbing the new file
          freesize = freesize()
          if size > freesize
            if size > (freeable() + freesize)
              raise KadeployError.new(
                APIError::CACHE_FULL,nil,
                "Impossible to cache the file '#{path}', the cache is full"
              )
            else
              unless free(size)
                raise KadeployError.new(
                  APIError::CACHE_FULL,nil,
                  "Impossible to cache the file '#{path}', the cache is full"
                )
              end
            end
          end
          acquire(size)
        end
      rescue Exception => e
        flock.unlock
        @locks.delete(fid)
        raise e
      end
    end # synchronize

    begin
      if create
        ret = fetch(path,version,user,priority,tag,size,file) do |f,o|
          yield(f,o,hit)
        end
        if ret.size != size
          delete(ret)
          raise KadeployError.new(APIError::CACHE_ERROR,nil,
            "The size of the file '#{path}' differs from the size announced before the download"
          )
        end
      end
    rescue Exception => e
      release(size)
      @locks.delete(fid)
      raise e
    ensure
      flock.unlock
    end

    ret
  end

  # Manually remove a file from the cache
  # returns:
  #   true: the element was removed
  #   false: the element was used so it was not possible to remove it
  #   nil: the element was not in the cache
  def remove(path,version,user,priority,tag='')
    fid = id({
      :path => path,
      :version => version,
      :user => user,
      :priority => priority,
      :tag => tag,
    })

    ret = nil
    # Get a lock on the file fid
    @lock.synchronize do
      if @locks[fid]
        flock = @locks[fid]
        flock.lock # Keep the global lock for the code to stay simple

        begin
          if ret = get(fid)
            if ret.used?
              ret = false
            else
              release(ret.size)
              delete(ret)
              @locks.delete(fid)
              ret = true
            end
          else
            ret = nil
          end
        ensure
          flock.unlock
        end
      else
        ret = nil
      end
    end

    ret
  end

  # Clean every cache values that are freeable and have a priority lesser or equal to max_priority
  def clean(max_priority=0)
    @lock.synchronize{ clean!(max_priority) }
  end

  def load(emptycache = true)
    if emptycache
      debug("Cleaning cache #{@directory} ...")
      exclude = [ '.', '..' ]
      files = []
      Dir.entries(@directory).sort.each do |file|
        rfile = File.join(@directory,file)
        if !exclude.include?(file)
          if @tagfiles
            if File.file?(rfile) \
              and file =~ CacheFile.regexp_filename(@prefix_base,CacheFile::EXT_FILE) \
            then
              meta = File.join(@directory,File.basename(file,CacheFile::EXT_FILE) + CacheFile::EXT_META)
              if File.file?(meta)
                Execute["rm -f #{meta}"].run!.wait
              end
              debug("Delete file #{File.basename(file)} from cache")
              Execute["rm -f #{rfile}"].run!.wait
            end
          else
            # Remove every files from directory if file not tagged
            debug("Delete file #{rfile} from cache")
            Execute["rm -f #{rfile}"].run!.wait
          end
        end
      end
      debug("Cache #{@directory} cleaned")
    else
      debug("Loading cache #{@directory} ...")
      exclude = [ '.', '..' ]
      files = []
      Dir.entries(@directory).sort.each do |file|
        rfile = File.join(@directory,file)
        if !exclude.include?(file)
          if @tagfiles
            if File.file?(rfile) \
              and file =~ CacheFile.regexp_filename(@prefix_base,CacheFile::EXT_FILE) \
            then
              meta = File.join(@directory,File.basename(file,CacheFile::EXT_FILE) + CacheFile::EXT_META)
              if File.file?(meta)
                files << CacheFile.load(rfile,meta,@prefix_base)
                Execute["rm -f #{meta}"].run!.wait
              else
                debug("Delete file #{rfile} from cache (no meta)")
                Execute["rm -f #{rfile}"].run!.wait
              end
            end
          else
            # Remove every files from directory if file not tagged
            debug("Delete file #{rfile} from cache")
            Execute["rm -f #{rfile}"].run!.wait
          end
        end
      end

      # Only keep the most recently used files with the greater priority
      @lock.synchronize do
        if @tagfiles
          files.sort_by{|v| "#{v.priority}#{v.atime.to_i}".to_i}.reverse!.each do |file|
            if file.priority != 0 and file.size <= freesize()
              if cfile = add(file)
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
      end # synchronize
      debug("Cache #{@directory} loaded (#{@cursize/(1024*1024)}MB)")
    end
  end

  protected
  # Every protected method has to be called with @lock taken

  def fetch(path,version,user,priority,tag='',size=nil,fpath=nil)
    # If new version have a greater priority (less chances to be deleted), change it: f.save if f.update(:priority => priority) if priority > f.priority
    ret = nil
    tmp = nil
    begin
      # The file don't exists, lets download and write it
      if fpath
        if !@tagfiles and File.exists?(fpath)
          raise KadeployError.new(
            APIError::CACHE_ERROR,nil,
            "Duplicate cache entries with the name '#{File.basename(path)}'"
          )
        end
        file = fpath
      else
        begin
          tmp = Tempfile.new('FETCH',@directory)
          file = tmp.path
        rescue
          raise KadeployError.new(
            APIError::CACHE_ERROR,nil,"Tempfiles cannot be created"
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
          APIError::CACHE_FULL,nil,
          "Impossible to cache the file '#{path}', the cache is full"
        )
      end
    ensure
      tmp.unlink if tmp
    end

    ret
  end

  def id(params={})
    @idxc.idx(params)
  end

  def get(fid)
    @files[fid]
  end

  def acquire(size)
    @cursize += size
  end

  def release(size)
    @cursize -= size
  end

  def add(file)
    idx = file.idx(@idxc)

    if @files[idx]
      @files[idx].replace(file,@idxc)
    else
      @files[idx] = file
    end

    @files[idx]
  end

  def delete(file)
    fid = file.idx(@idxc)
    @files[fid].remove()
    @files.delete(fid)
  end

  def freeable()
    size = 0
    @files.each_value do |file|
      size += file.size unless file.used?
    end
    size
  end

  def freesize()
    @maxsize - @cursize
  end

  def free(amount=0)
    amount = @maxsize if amount == 0
    #return true if amount < freesize()

    # Delete all elements with prio 0 (elements in cache for a single usage)
    clean!(0)

    return true if amount < freesize()

    # Delete elements depending on their priority and last access time
    # (Do not use cleanables() since there is too much race conditions)
    @files.values.sort_by{|v| "#{v.priority}#{v.atime.to_i}".to_i}.each do |file|
      return true if amount < freesize()
      unless file.used?
        flock = @locks[file.idx(@idxc)]
        flock.synchronize do
          release(file.size)
          delete(file)
          @locks.delete(file.idx(@idxc))
        end
      end
    end

    return amount < freesize()
  end

  def clean!(max_priority=0)
    @files.values.each do |file|
      if file.priority <= max_priority and !file.used?
        flock = @locks[file.idx(@idxc)]
        flock.synchronize do
          release(file.size)
          delete(file)
          @locks.delete(file.idx(@idxc))
        end
      end
    end
  end
end

end
