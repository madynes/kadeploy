# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

require 'tempfile'
require 'net/http'
require 'net/https'
require 'uri'
require 'error'

module HTTP
  public
  # Fetch a file over HTTP
  #
  # Arguments
  # * uri: URI of the file
  # * output: output file
  # * cache_dir: cache directory
  # * etag: ETag of the file (http_response is -1 if Tempfiles cannot be created)
  # Output
  # * return http_response and ETag
  def HTTP::fetch_file(uri, output, cache_dir, expected_etag)
    http_response = String.new
    etag = String.new
    begin
      if cache_dir
        wget_output = Tempfile.new("wget_output", cache_dir)
        wget_download = Tempfile.new("wget_download", cache_dir)
      else
        wget_output = Tempfile.new("wget_output")
        wget_download = Tempfile.new("wget_download")
      end
    rescue StandardError
      return -1,0
    end
    if (expected_etag == nil) then
      cmd = "LANG=C wget --debug #{uri} --no-check-certificate --output-document=#{wget_download.path} 2> #{wget_output.path}"
    else
      cmd = "LANG=C wget --debug #{uri} --no-check-certificate --output-document=#{wget_download.path} --header='If-None-Match: \"#{expected_etag}\"' 2> #{wget_output.path}"
    end
    system(cmd)
    http_response = `grep "^HTTP/1\.." #{wget_output.path}|tail -1|cut -f 2 -d' '`.chomp
    if (http_response == "200") then
      if not system("mv #{wget_download.path} #{output}") then
        return -2,0
      end
    end
    etag = `grep "ETag" #{wget_output.path}|cut -f 2 -d' '`.chomp
    wget_output.unlink
    return http_response.to_i, etag
  end

  def HTTP::check_file(uri, expected_etag=nil)
    http_response = String.new
    etag = String.new
    wget_output = Tempfile.new("wget_output")

    cmd = "LANG=C wget --debug --spider #{uri} --no-check-certificate"
    if expected_etag
      cmd += " --header='If-None-Match: \"#{expected_etag}\"'"
    end
    cmd += " 2>#{wget_output.path}"
    system(cmd)

    http_response = `grep "^HTTP/1\.." #{wget_output.path}|tail -1|cut -f 2 -d' '`.chomp
    etag = `grep "ETag" #{wget_output.path}|cut -f 2 -d' '`.chomp
    wget_output.unlink

    return http_response.to_i, etag
  end

  # Get a file size over HTTP
  #
  # Arguments
  # * uri: URI of the file
  # Output
  # * return the file size, or nil in case of bad URI
  def HTTP::get_file_size(uri)
    url = URI.parse(uri)
    resp = nil
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = url.is_a?(URI::HTTPS)
    http.start
    resp = http.head(url.path)
    raise KadeployHTTPError.new(resp.code) unless resp.is_a?(Net::HTTPSuccess)
    return resp['content-length'].to_i
  end
end
