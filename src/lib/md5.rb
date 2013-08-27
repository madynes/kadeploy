
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
