# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Ruby libs
require 'ftools'

class CacheFile
  PREFIX_BASE = '_kacache'
  attr_reader :user, :priority, :md5, :size, :mtime, :lock
  
  def initialize(file,user,priority)
    raise ArgumentError.new("Invalid file '#{path}'") if !File.file?(file) \
      or !File.readable?(file) or !File.readable_real?(file)
    @file = file
    @priority = priority
    @user = user
    load()
  end

  def load()
    @mtime = File.mtime(@file)
    @md5 = MD5::get_md5_sum(@file)
    @size = File.size(@file)
    @lock = Mutex.new
  end

  def fileid()
    "#{prefix(@user,@priority)}#{File.basename(@file)}-#{@md5}-#{@mtime.to_i}"
  end

  def touch()
    Execute["touch -m #{@path}"].run!
    @mtime = File.mtime(@path)
  end

  def self.prefix(user,priority)
    "#{PREFIX_BASE}_p-#{priority}_u-#{user}_"
  end

  def self.parse_user(file)
    filename = File.basename(file)
    if filename ~= /^#{PREFIX_BASE}_p-\d+_u-(.+)_.*$/
      Regexp.last_match(1)
    else
      nil
    end
  end

  def self.parse_priority(file)
    filename = File.basename(file)
    if filename ~= /^#{PREFIX_BASE}_p-(\d+)_u-.+_.*$/
      Regexp.last_match(1)
    else
      nil
    end
  end
end

class Cache
  PRIORITIES = {
    :anon => 1,
    :db => 2,
  }

  def initialize(directory, maxsize = 0)
    @directory = directory # TODO: absolute path
    @cursize = 0 # Bytes
    @maxsize = maxsize # TODO: in Bytes
    @files = {}
    load()
  end

  # Cache a file and get a path to the cached version
  def cache(file)
  end

  # Free (at least) a specific amout of memory in the cache
  def free(amount)
  end

  # Clean every cache values that are freeable and have a priority lesser than max_priority
  def clean(max_priority)
  end

  def load()
    exclude = [ '.', '..' ]
    Dir.foreach(@directory) do |file|
      rfile = File.join(@directory,file)
      if !exclude.include?(file) \
        and File.file?(rfile) \
        and File.readable?(rfile) \
        and File.readable_real?(rfile) \
        and file =~ /^#{PREFIX_BASE}\[(\d+)\].*$/ \
      then
        add(rfile,CacheFile.parse_user(rfile),CacheFile.parse_priority(rfile))
      end
    end
  end

  protected
  def add(filepath,user,priority)
    file = CacheFile.new(filepath,user,priority)
    @files[file.fileid] = file
    @cursize += file.size
    file
  end

  def delete(fileid)
    @files.delete(fileid)
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
