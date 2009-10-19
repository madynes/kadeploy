# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

require 'tempfile'
require 'net/http'
require 'uri'

module HTTP
  public
  # Fetch a file over HTTP
  #
  # Arguments
  # * uri: URI of the file
  # * output: output file
  # * etag: ETag of the file
  # Output
  # * return http_response and ETag
  def HTTP::fetch_file(uri, output, expected_etag)
    http_response = String.new
    etag = String.new
    wget_output = Tempfile.new("wget_output")
    wget_download = Tempfile.new("wget_download")
    if (expected_etag == nil) then
      cmd = "LANG=C wget --debug #{uri} --no-check-certificate --output-document=#{wget_download.path} 2> #{wget_output.path}"
    else
      cmd = "LANG=C wget --debug #{uri} --no-check-certificate --output-document=#{wget_download.path} --header='If-None-Match: \"#{expected_etag}\"' 2> #{wget_output.path}"
    end
    system(cmd)
    http_response = `grep "HTTP/1.1" #{wget_output.path}|cut -f 2 -d' '`.chomp
    if (http_response == "200") then
      if not system("mv #{wget_download.path} #{output}") then
        return nil
      end
    end
    etag = `grep "ETag" #{wget_output.path}|cut -f 2 -d' '`.chomp
    wget_output.unlink
    return http_response, etag
  end

  # Get a file size over HTTP
  #
  # Arguments
  # * uri: URI of the file
  # Output
  # * return the file size
  def HTTP::get_file_size(uri)
    url = URI.parse(uri)
    resp = nil
    Net::HTTP.start(url.host, url.port) { |http|
      resp = http.head(url.path)
    }
    return resp['content-length'].to_i
  end
end
