require 'pathname'
require 'thread'
require 'fileutils'
require 'digest'
require 'digest/md5'
require 'uri'
require 'yaml'
require 'set'

YAML::ENGINE.yamler = 'syck' if RUBY_VERSION >= '1.9'

module Kadeploy

  #Used for environments
  class CacheIndexPVHash
    def self.name(params)
      if params[:tag]
        "#{params[:tag]}-#{params[:version].to_s}-#{params[:origin_uri]}".gsub(/\W/,'_')+".data"
      else
        "#{params[:version].to_s}-#{params[:origin_uri]}".gsub(/\W/,'_')+".data"
      end
    end
  end

  #Used for user file boot
  class CacheIndexPath
    def self.name(params)
        raise KadeployError.new(APIError::CACHE_ERROR,nil,"In CacheIndexPath the file_in_cache must be provided") if params[:file_in_cache].nil?
        params[:file_in_cache]
    end
  end


  class CacheFile
    EXT_META = 'meta'
    EXT_FILE = 'data'

    MODE=0640

    #This function checks if a file is readable.
    #It raises an exception if the file is not readable.
    def self.readable?(file)
      raise KadeployError.new(APIError::CACHE_ERROR,nil,"File '#{file}' is not readable") if !File.file?(file) or !File.readable?(file) or !File.readable_real?(file)
    end

    #Load CacheFile from meta_file.
    def self.load(meta_file)
      readable?(meta_file)
      meta = YAML.load_file(meta_file)

      ret = self.new(
        meta[:file_in_cache],
        meta[:user],
        nil,
        false #this avoids to create a new meta file, this parameter will be overridden by the next lines.
      )
      meta.each_pair do |key,value|
        ret.instance_variable_set("@#{key}", value)
      end
      ret
    end

    attr_reader :user, :priority, :origin_uri , :version, :tag, :md5, :size
    attr_reader :mtime, :lock, :refs, :fetched, :fetch_error,:file_in_cache,:meta


    # file_in_cache: is the filename in a cache this parameter could not be nil.
    # Arguments:
    #   +file_in_cache: path where the file is stored in cache
    #   +user: user who stores the file
    #   +directory: directory where the meta will be stored
    #   +save_meta: boolean which enables or disables the meta file writing
    def initialize(file_in_cache, user, directory, save_meta=false)
      @lock = Mutex.new              #: Lock of file
      @user = user.clone             #: The user who has cached the file
      @version = nil                 #: The version of the file
      @priority = 0                  #: The lower priority will be deleted before the higher priority. At end, kaworkflow deletes all files with priority 0.
      @file_in_cache = file_in_cache #: The file path inside the cache system
      @refs = Set.new                #: list of references wid
      @fetched = false               #: Fetch status
      @fetch_error = nil             #: Potential fetch error
      @size = 0                      #: Size of cached file
      update_atime
      if save_meta && directory
        @meta = meta_file(directory)
        save!()
      else
        @meta = nil
      end
    end


    # Fetch file to the cache if md5, mtime, size, or version have been modified
    # It raises an exception if the file is updated when it is used.
    # If no block is given it uses cp command.
    # Arguments:
    #  +user who store the file
    #  +origin_uri is uri source of file
    #  +priority is fixnum of PRIORITIES in Cache class.
    #  +version is the version of file
    #  +size is the size file
    #  +md5 is md5 checksum of file
    #  +tag is the tag of file
    #  +block is the block to fetch file.
    #     block has four parameters : origin_uri, file_in_cache,size and md5 which are the parameter of this function
    def fetch(user,origin_uri,priority,version,size,md5,mtime,tag,&block)
      @lock.synchronize do
        if @fetched # File has already been fetched
          if ( mtime != @mtime || ( size > 0 && size != @size) || version != @version || md5 != @md5 ) #Update
            raise KadeployError.new(APIError::CACHE_ERROR,nil,"File #{origin_uri} is already in use, it can't be updated !\nPlease try again later.") if @refs.size > 1
            get_file(user,origin_uri,priority,version,size,md5,mtime,tag,&block)      # We assume that an update can dammage a file.
          end
        else
          get_file(user,origin_uri,priority,version,size,md5,mtime,tag,&block)
        end
      end
    end

    #Update size if it changed.
    #If the file is already in use it raise an exception.
    def update_size(size)
      @lock.synchronize do
        if @size != size
          raise KadeployError.new(APIError::CACHE_ERROR,nil,"File #{origin_uri} is already in use, it can't be updated !\nPlease try again later.") if @refs.size > 1
          @size = size
          @fetched = false
        end
      end
    end

    #Return true if file is used false otherwise
    def used?()
      if @lock.try_lock
        ret = used!()
        @lock.unlock
        ret
      else
        true
      end
    end

    #Update the virtual access time
    #and return the @file_in_cache
    def file()
      raise KadeployError.new(APIError::CACHE_ERROR,nil,"This file has been freed!") if is_freed?()
      raise KadeployError.new(APIError::CACHE_ERROR,nil,"This file has not been fetched") if !@fetched
      raise KadeployError.new(APIError::CACHE_ERROR,nil,"An error occurs when it was fetched! #{@fetched_error}") if @fetch_error
      update_atime()
      @file_in_cache
    end

    # Take a token
    def acquire(wid)
      @lock.synchronize do
        @refs.add(wid)
      end
    end

    # Release a token
    def release(wid)
      @lock.synchronize do
        @refs.delete(wid)
      end
    end

    #Update virtual access time, this replaces FS atime
    def update_atime()
      @atime_virt = Time.now.to_i
      self
    end

    #Get access time. Relying on the FS information might not be reliable (noatime mount option for instance)
    def atime()
      @atime_virt
    end

    #Try to free the file
    # Output:
    #   - file_in_cache path if the operation was a success
    #   - nil else
    def try_free()
      locked=false
      begin
        locked = @lock.try_lock
        if locked
          return false if used!
          FileUtils.rm_f(@file_in_cache) if File.exist?(@file_in_cache)
          FileUtils.rm_f(@meta) if @meta && File.exist?(@meta)
          @atime_virt = nil
          @md5 = nil
          file = @file_in_cache
          @file_in_cache = nil
          return file
        end
      ensure
        @lock.unlock if locked
      end
      nil
    end

    #Check if the file is freed or not.
    def is_freed?()
      @file_in_cache.nil?
    end

    #Return hash of structure (for testing purpose)
    def to_hash()
      @lock.synchronize do
         to_hash!()
      end
    end

    private

    #Generate the path to store the meta file
    def meta_file(directory)
      File.join(directory,File.basename(@file_in_cache,"."+EXT_FILE)) + "."+EXT_META
 ##
 ## If CacheIndexPath is used and if the cache saves the meta data then a conflict of meta file name is possible
 ## since the meta file is named according to the filename only. For example if /toto/example.txt and /titi/example.txt
 ## are cached, both files will write /dircache/example.txt.meta.
 ## In this case, the following code will create two files: example.txt.meta and example.txt-1.meta.
 ## Since this feature is not currently used in Kadeploy, the code is commented.
 #     i = 1
 #     while(File.exists?(ret)) do
 #       ret = File.join(directory,"#{File.basename(@file_in_cache,EXT_FILE)}-#{i}") +  EXT_META
 #       i+=1
 #     end
 #     ret
    end

    #Check if file is still used
    def used!()
      (@refs.size > 0)
    end

    #Transform variables to hash format
    def to_hash!()
      ret = {}
      instance_variables.each do |instvar|
        ret[instvar[1..-1].to_sym] = instance_variable_get(instvar)
      end
      ret.delete(:lock)
      ret.delete(:refs)
      ret
    end

    #Save the object field in @meta file in hash format
    #
    # !!! Be careful, use lock
    def save!()
      return unless @meta
      content = to_hash!()
      File.open(@meta,"w") do |f|
        f.write(content.to_yaml)
      end
      self
    end

    #Put file into the cache and update the data structure
    #Arguments: see the fetch function
    def get_file(user,origin_uri,priority,version,size,md5,mtime,tag,&block)
      begin
        @user = user
        @priority = priority
        @version = version
        @tag = tag
        if block_given?
          yield(origin_uri,@file_in_cache,size,md5)
        else
          raise KadeployError.new(APIError::CACHE_ERROR,nil,"File size mistmatch") if size > 0 && size != File.size(origin_uri)
          raise KadeployError.new(APIError::INVALID_FILE, ("Checksum of the file '#{origin_uri}' does not match "\
          "(an update is necessary)")) if md5 && md5 != Digest::MD5.file(origin_uri).hexdigest!
          FileUtils.cp(origin_uri,@file_in_cache)
        end
        #update all parameters if fetch raise nothing
        @origin_uri = origin_uri
        @mtime = mtime
        @size = File.size(@file_in_cache)
        update_atime
        @md5 = md5
        @fetched = true
        @fetched_error = nil
        save!()
      rescue Exception => ex
        @fetched = false
        @fetched_error=ex
        FileUtils.rm_f(@file_in_cache) if @file_in_cache && File.exist?(@file_in_cache)
        raise ex
      end
    end
  end

  class Cache

    # Be careful, elements with priority 0 are not kept in cache after use (suitable for anonymous deployments)
    # Different priorities
    # 0: anonymous deleted at end
    # 1: anonymous not deleted at end
    # 2: database
    PRIORITIES = {
      :anon => 0,
      :anon_keep => 1,
      :db => 2,
    }

    attr_reader :directory, :max_size, :files

    # Be carefully the file is written in path given by idxmeth.
    # Arguments:
    #   +directory: directory by default and directory where meta will be written
    #   +max_size is maximum size in Bytes
    #   +naming_metsh is object which contains name function with all parameter of cache and it gives the path where file will be stored
    #   +emptycache is a boolean the cache is cleaned at start if true and loaded from finded meta file in directory at start
    #   +same_meta boolean which enable or disable the meta saving.
    def initialize(directory, max_size, naming_meth, emptycache=true, save_meta=false)
      raise KadeployError.new(APIError::CACHE_ERROR,nil,"#{directory} is not a directory") if directory && !File.directory?(directory)
      raise KadeployError.new(APIError::CACHE_ERROR,nil,"Save meta without directory is not allowed") if save_meta && directory.nil?
      raise KadeployError.new(APIError::CACHE_ERROR,nil,"Invalid cache size '#{max_size}'") if !(max_size.is_a?(Fixnum) or max_size.is_a?(Bignum))  or max_size <= 0

      @directory = directory
      @max_size = max_size     # Bytes
      @files = {}
      @naming_meth = naming_meth
      @lock = Mutex.new
      @save_meta = save_meta
      load(emptycache)
    end

    def debug(msg)
      puts msg
    end


    # Cache puts the file at origin_uri in cache
    # if block is given it used to get file
    # else a simple cp is used
    #
    # This function takes a token.
    # This token must be released at end.
    #
    # Arguments:
    #  +origin_uri is uri source of file
    #  +version is the version of file
    #  +user who store the file
    #  +priority is fixnum of PRIORITIES
    #  +size is the size file
    #  +wid is the identifier of the operation. It's useful to release all tokens even if the token was lost by a kill of the main thread.
    #  +md5 is MD5 checksum of file
    #  +tag is the tag of file
    #  +block is the block to fetch file
    #     block has four parameters : origin_uri, file_in_cache,size and md5 which are the parameter of this function
    # Output:
    #   FileCache
    # This function take a token that have to be released after a deployment
    def cache(origin_uri,version,user,priority,tag,size,wid,file_in_cache=nil,md5=nil,mtime=nil,&block)
      raise("The priority argument is nil in cache call") if priority.nil?
      fentry = absolute_path(@naming_meth.name({
          :origin_uri => origin_uri,
          :version => version,
          :file_in_cache => file_in_cache,
          :user => user,
          :priority => priority,
          :size => size,
          :md5 => md5,
          :tag => tag,
          :mtime => mtime,
      }))

      file = nil

      begin
        @lock.synchronize do
           file = @files[fentry]
           if !file
              file =  CacheFile.new(fentry,user,@directory,@save_meta)
              @files[fentry] = file
           end
           file.acquire(wid)
           check_space_and_clean!(size-file.size,origin_uri)
           file.update_size(size)
        end
        file.fetch(user,origin_uri,priority,version,size,md5,mtime,tag,&block)
      rescue Exception => ex
        @lock.synchronize do
          file.release(wid)
          if !file.fetched && file.try_free
            @files.delete(fentry)
          end
        end
        raise ex
      end
      file
    end

    #Transform path into absolute path.
    # Argument:
    #  +path
    # Output
    #  Absolute path of path
    def absolute_path(file)
      begin
        file = File.expand_path(file,@directory)
      rescue ArgumentError
        raise KadeployError.new(APIError::CACHE_ERROR,nil,"Invalid path '#{file}'")
      end
      file
    end

    #Return the number of files
    def nb_files()
      @files.size
    end

    # Clean clean the cached files that are releasable and have a priority lower or equal to max_priority
    # if max_priority is negative, it tries to free all files.
    def clean(max_priority=0)
      @lock.synchronize do
        to_del=[]
        @files.each_value do |file|
          if file.priority <= max_priority or max_priority<0
            if fentry = file.try_free
              to_del<<fentry
            end
          end
        end
        to_del.each do |fentry|
          @files.delete(fentry)
        end
      end
    end

    # Release the token of wid
    def release(wid)
      @lock.synchronize do
        @files.each_value do |f|
          f.release(wid)
        end
      end
    end


    #Load cache with different policy:
    # -if @directory == nil: do nothing
    # -if empty_cache == true : erase files in directory
    # -else all meta file inside @directory are loaded
    def load(emptycache = true)
      return if @directory.nil? # No directory is provided
      if emptycache
        debug("Cleaning cache #{@directory} ...")
        exclude = [ '.', '..' ]
        files = []
        Dir.entries(@directory).sort.each do |file|
          rfile = File.join(@directory,file)
          if !exclude.include?(rfile)
            if File.file?(rfile)
              debug("Delete file #{rfile} from cache")
              FileUtils.rm_f(rfile)
            end
          end
        end
        debug("Cache #{@directory} cleaned")
      else
        debug("Loading cache #{@directory} ...")
        exclude = [ '.', '..' ]
        files = []
        @lock.synchronize do
          Dir.entries(@directory).sort.each do |file|
            rfile = File.join(@directory,file)
            if !exclude.include?(file) && file.split('.').last == CacheFile::EXT_META
              begin
                fc = CacheFile.load(rfile)
                @files[fc.file_in_cache] = fc
              rescue Exception => ex
                debug("Unable to load #{rfile}: #{ex}")
                debug(ex.backtrace.join("\n"))
              end
            end
          end
        end
        debug("Cache #{@directory} loaded with #{@files.size} files")
      end
    end

    #Free all resources
    #Raise an exception if there is a file still used !
    def free()
      clean(-1)
      if @files.size > 0
        raise KadeployError.new(APIError::CACHE_ERROR,
                nil,
                "Many files are used: #{@files.values.map{|f| "#{f.file_in_cache} by workflow #{f.refs.to_a.join(', ')}"}.join("\n")}"
        )
      end
    end

    private

    # Methods named with  '!' at their end have to be called with @lock taken

    # Arguments:
    #  +size: size of file
    #  +origin_uri: origin of file
    # Output:
    #   none
    # Raise an exception if size is greater than we can free.
    def check_space_and_clean!(size, origin_uri)
      return if size <= 0
      # If a size is given, clean the cache before grabbing the new file
      unfreeable,used_space = compute_space!()

      if size > @max_size - unfreeable
          raise KadeployError.new(
            APIError::CACHE_FULL,nil,
            "Cache is full: impossible to cache the file '#{origin_uri}'"
          )
      end
      free_space!(size - (@max_size - used_space))
    end

    #Compute the releasable and the used cache space
    #Output:
    # Array[ file cache used in byte, total of file cache in byte ]
    def compute_space!()
      unfreeable_space = 0
      used_space = 0
      @files.each_value do |file|
        unfreeable_space += file.size if file.used?
        used_space += file.size
      end
     [unfreeable_space,used_space]
    end

    #This function removes low priority elements until having enough free space (need_to_free)
    def free_space!(need_to_free)
      return true if need_to_free <= 0

      # Delete elements depending on their priority and according to an LRU policy
      begin
      ensure
        @files.values.sort_by{|v| [v.priority,v.atime]}.each do |file|
          return true if need_to_free <= 0
          size = file.size
          fid = file.try_free
          if fid
            @files.delete(fid)
            need_to_free -= size
          end
        end
      end
    end
  end
end
