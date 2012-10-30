# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Ruby libs
require 'pathname'
require 'thread'
require 'fileutils'
#require 'ftools'

#Kadeploy3 libs
require 'error'
require 'md5'
require 'execute'

class CacheFile
  MODE=0640
  FSEP_VALUE='%'
  FSEP_AFFECT='='

  attr_reader :file, :user, :priority, :basename, :md5, :size, :atime, :mtime, :lock, :fid, :filename

  def initialize(file,prefix,basename,user,priority,tag='')
    begin
      file = Pathname.new(file).realpath.to_s
    rescue Errno::ENOENT
      raise FetchFileError::CACHE_INTERNAL_ERROR
    end

    raise FetchFileError::CACHE_INTERNAL_ERROR if !File.file?(file) \
      or !File.readable?(file) or !File.readable_real?(file)

    @file = file
    @basename = basename
    @prefix = prefix
    @priority = priority
    @user = user
    @tag = tag
    @lock = Mutex.new

    refresh()
  end

  def refresh()
    @lock.synchronize{ refresh!() }
  end

  # !!! Be careful, use lock
  def refresh!()
    @mtime = File.mtime(@file)
    @atime = File.atime(@file)
    @md5 = MD5::get_md5_sum(@file)
    @size = File.size(@file)
    @fid = self.class.genfid(@user,@basename,@md5)
    @filename = self.class.genfilename(@prefix,@fid,@priority,@tag)
  end

  def update_atime()
    Execute["touch -a #{@file}"].run!
    @atime = File.atime(@file)
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
      begin
        directory = Pathname.new(directory).realpath.to_s
      rescue Errno::ENOENT
        raise FetchFileError::CACHE_INTERNAL_ERROR
      end
      raise FetchFileError::CACHE_INTERNAL_ERROR unless File.directory?(directory)

#puts "mv #{@file} #{File.join(directory,@filename)}"
      FileUtils.mv(@file,File.join(directory,@filename))
      @file = File.join(directory,@filename)
      FileUtils.chmod(MODE,@file)
      update_mtime!() if @mtime.nil?
      update_atime!() if @atime.nil?
    end
    self
  end

  def replace(newfile)
    @lock.synchronize{ replace!(newfile) }
  end

  def replace!(newfile)
    if newfile.filename != @filename
#puts 'replace'
      newfile.remove() if @fid != newfile.fid
      @file = newfile.file
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
    @fid = nil
    @filename = nil

    self
  end

  def self.load(file,prefix)
    begin
      file = Pathname.new(file).realpath.to_s
    rescue Errno::ENOENT
      raise FetchFileError::CACHE_INTERNAL_ERROR
    end

    raise FetchFileError::CACHE_INTERNAL_ERROR if !File.file?(file) \
      or !File.readable?(file) or !File.readable_real?(file)

    self.new(
      file,
      prefix,
      parse_basename(file,prefix),
      parse_user(file,prefix),
      parse_priority(file,prefix),
      parse_tag(file,prefix)
    )
  end

  def self.genval(key,val)
    "#{FSEP_VALUE}#{key}#{FSEP_AFFECT}#{(val.is_a?(Regexp) ? val.source : val.to_s)}"
  end

  def self.genfid(user,basename,md5)
    "#{genval('u',user)}#{genval('f',basename)}#{genval('h',md5)}"
  end

  def self.genfilename(prefix,fid,priority,tag)
    "#{prefix}#{genval('p',priority)}#{fid}#{genval('t',tag)}"
  end

  def self.fid(user,file)
    begin
      file = Pathname.new(file).realpath.to_s
    rescue Errno::ENOENT
      raise FetchFileError::CACHE_INTERNAL_ERROR
    end

    raise FetchFileError::CACHE_INTERNAL_ERROR if !File.file?(file) \
      or !File.readable?(file) or !File.readable_real?(file)
  end

  def self.regexp_fid()
    /#{genval('u',/(.+)/)}#{genval('f',/(.+)/)}#{genval('h',/([0-9a-fA-F]+)/)}/
  end

  def self.regexp_filename(prefix_base)
    /^#{prefix_base}#{genval('p',/(\d+)/)}#{regexp_fid.source}#{genval('t',/(.*)/)}$/
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

  def self.parse_basename(file,prefix)
    filename = File.basename(file)
    if filename =~ regexp_filename(prefix)
      Regexp.last_match(3)
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
  def initialize(directory, maxsize, prefix_base = PREFIX_BASE)
    begin
      directory = Pathname.new(directory).realpath.to_s
    rescue Errno::ENOENT
      raise FetchFileError::CACHE_INTERNAL_ERROR
    end
    raise FetchFileError::CACHE_INTERNAL_ERROR unless File.directory?(directory)
    raise FetchFileError::CACHE_INTERNAL_ERROR unless maxsize.is_a?(Fixnum) and maxsize > 0

    @directory = directory
    @cursize = 0 # Bytes
    @maxsize = maxsize # TODO: in Bytes
    @prefix_base = prefix_base
    @files = {}
    @lock = Mutex.new
    load()
  end

  # Cache a file and get a path to the cached version
  def cache(file,user,priority,tag='',basename=nil)
    tmpfile = CacheFile.new(
      file,@prefix_base,(basename.nil? ? File.basename(file) : basename),user,priority,tag
    )
    fid = tmpfile.fid
    if @files[fid]
      # If new version have a greater priority (less chances to be deletes), change it
      if tmpfile.priority > @files[fid].priority
        @files[fid].replace(file)
        @files[fid].save
      end
      @files[fid].update_atime()
    else
      add(tmpfile)
    end
    #if in cache file.update_atime + verifs, else load file in cache
  end

  # Free (at least) a specific amout of memory in the cache
  def free(amount)
    @lock.synchronize{ free!(amount) }
  end

  # !!! Be careful, use lock
  def free!(amount)
    return true if amount < freesize!()
    cleanables!().each do |file|
      return true if amount < freesize!()
      delete!(file.fid)
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
      delete(file.fid)
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
        unless add(CacheFile.load(rfile,@prefix_base))
          FileUtils.rm_f(rfile)
#puts "rm #{file}"
        end
      end
    end
  end

  protected

  def add(file)
    @lock.synchronize do
      return nil if file.size > @maxsize
      if file.size > freesize!()
        return nil unless free!(file.size)
      end
      fid = file.fid

      if @files[fid]
        @files[fid].replace(file)
      else
        @files[fid] = file
      end

      @files[fid].save(@directory)
      @cursize += file.size

      @files[fid]
    end
  end

  def delete(fid)
    @lock.synchronize{ delete!(fid) }
  end

  def delete!(fid)
#puts "delete #{fid}"
    #@cursize -= @files[fid].size
    @cursize -= @files[fid].remove().size
    @files.delete(fid)
  end

  def include?(file)
  end

  def full?()
  end
end

=begin

module Cache
  private

  # Get the size of a directory (including sub-dirs)
  # Arguments
  # * dir: dirname
  # * output: OutputControl instance
  # Output
  # * returns the size in bytes if the directory exist, 0 otherwise
  def Cache::get_dir_size_with_sub_dirs(dir, output)
    sum = 0
    if FileTest.directory?(dir) then
      begin
        Dir.foreach(dir) { |f|
          full_path = File.join(dir, f)
          if FileTest.directory?(full_path) then
            if (f != ".") && (f != "..") then
              sum += get_dir_size(full_path, output)
            end
          else
            sum += File.stat(full_path).size
          end
        }
      rescue
        output.debug_server("Access not allowed in the cache: #{$!}")
      end
    end
    return sum
  end

  # Get the size of a directory (excluding sub-dirs)
  # Arguments
  # * dir: dirname
  # * output: OutputControl instance
  # Output
  # * returns the size in bytes if the directory exist, 0 otherwise
  def Cache::get_dir_size_without_sub_dirs(dir, output)
    sum = 0
    if FileTest.directory?(dir) then
      begin
        Dir.foreach(dir) { |f|
          full_path = File.join(dir, f)
          if not FileTest.directory?(full_path) then
            sum += File.stat(full_path).size
          end
        }
      rescue
        output.debug_server("Access not allowed in the cache: #{$!}")
      end
    end
    return sum
  end


  public

  # Clean a cache according to an LRU policy
  #
  # Arguments
  # * dir: cache directory
  # * max_size: maximum size for the cache in Bytes
  # * time_before_delete: time in hours before a file can be deleted
  # * pattern: pattern of the files that might be deleted
  # * output: OutputControl instance
  # Output
  # * nothing
  def Cache::clean_cache(dir, max_size, time_before_delete, pattern, output)
    no_change = false
    files_to_exclude = Array.new
    while (get_dir_size_without_sub_dirs(dir, output) > max_size) && (not no_change)
      lru = ""
      
      begin
        Dir.foreach(dir) { |f|
          full_path = File.join(dir, f)
          if (!files_to_exclude.include?(full_path)) then
            if (((f =~ pattern) == 0) && (not FileTest.directory?(full_path))) then
              access_time = File.atime(full_path).to_i
              now = Time.now.to_i
              #We only delete the file older than a given number of hours
              if  ((now - access_time) > (60 * 60 * time_before_delete)) && ((lru == "") || (File.atime(lru).to_i > access_time)) then
                lru = full_path
              end
            end
          end
        }
        if (lru != "") then
          begin
            File.delete(lru)
          rescue
            output.debug_server("Cannot delete the file #{lru}: #{$!}")
            files_to_exclude.push(lru);
          end
        else
          no_change = true
        end
      rescue
        output.debug_server("Access not allowed in the cache: #{$!}")
      end
    end
  end
  
  # Remove some files in a cache
  #
  # Arguments
  # * dir: cache directory
  # * pattern: pattern of the files that must be deleted
  # * output: OutputControl instance
  # Output
  # * nothing
  def Cache::remove_files(dir, pattern, output)
    Dir.foreach(dir) { |f|
      full_path = File.join(dir, f)
      if (((f =~ pattern) == 0) && (not FileTest.directory?(full_path))) then
        begin
          File.delete(full_path)
        rescue
          output.debug_server("Cannot delete the file #{full_path}: #{$!}")
        end
      end
    }
  end
end
=end
