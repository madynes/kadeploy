# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Ruby libs
require 'ftools'

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
