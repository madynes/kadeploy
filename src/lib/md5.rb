# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

module MD5
  # Compute the md5 sum of a file
  #
  # Arguments
  # * file: filename
  # Output
  # * return the md5 of the file
  def MD5::get_md5_sum(file)
    return `md5sum #{file}|cut -f1 -d" " `.chomp
  end
end
