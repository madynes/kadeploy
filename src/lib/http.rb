require 'tempfile'
require 'net/http'
require 'net/https'
require 'uri'
require 'error'
require 'time'

module Kadeploy

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
  def self.fetch_file(uri, output, cache_dir, expected_etag)
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

  def self.check_file(uri, expected_etag=nil)
    url = URI.parse(uri)
    resp = nil
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = url.is_a?(URI::HTTPS)
    http.start
    opts = {}
    opts['If-None-Match'] = expected_etag if expected_etag
    resp = http.head(url.path,opts)
    raise KadeployHTTPError.new(resp.code) if !resp.is_a?(Net::HTTPSuccess) and !resp.is_a?(Net::HTTPNotModified)
    return resp.to_hash
  end

  # Get a file size over HTTP
  #
  # Arguments
  # * uri: URI of the file
  # Output
  # * return the file size, or nil in case of bad URI
  def self.get_file_size(uri)
    return self.check_file(uri)['content-length'][0].to_i
  end

  def self.get_file_mtime(uri)
    return Time.parse(self.check_file(uri)['last-modified'][0]).to_i
  end

  class ClientError < Exception
  end

  class Client
    def self.error(msg='')
      raise ClientError.new(msg)
    end

    def self.path_params(path,params)
      path = path[0..-2] if path[-1] == '/'
      "#{path}?#{URI.encode_www_form(params)}"
    end

    def self.connect(server,port,secure=true)
      begin
        client = Net::HTTP.new(server, port)
        if secure
          client.use_ssl = true
          client.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end
        client.set_debug_output($debug_http) if $debug_http
        yield(client)
      rescue Errno::ECONNREFUSED
        error("Connection atempt refused by the server")
      end
    end

    def self.request(server,port,secure=true,request=nil)
      res = nil
      connect(server,port,secure) do |client|
        begin
          request = yield(client) unless request
          raise unless request.is_a?(Net::HTTPRequest)
          response = client.request(request)
        rescue Exception => e
          error("Invalid request on #{server}:#{port}\n#{e.message} (#{e.class.name})")
        end
        if response.is_a?(Net::HTTPOK)
          if response['Content-Type'] == 'application/json'
            res = JSON::load(response.body)
          elsif response['Content-Type'] == 'text/plain'
            res = response.body
          else
            error("Invalid server response (Content-Type: '#{response['Content-Type']}')")
          end
        else
          case response.code.to_i
          when 400
            if response['X-Application-Error-Code']
              error("[Kadeploy Error ##{response['X-Application-Error-Code']}]\n#{response.body}")
            else
              error(
                "[HTTP Error ##{response.code} on #{method.to_s} #{request.path}]\n"\
                "-----------------\n"\
                "#{response.body}\n"\
                "-----------------"
              )
            end
          when 500
            error("[Internal Server Error]\n#{response.body}")
          else
            error(
              "[HTTP Error ##{response.code} on #{request.method} #{request.path}]\n"\
              "-----------------\n"\
              "#{response.body}\n"\
              "-----------------"
            )
          end
        end
      end
      res
    end

    def self.gen_request(kind,path,data=nil,content_type='application/json')
      header = { 'Accept' => 'text/plain, application/json' }
      if data
        header['Content-Type'] = content_type
        header['Content-Length'] = data.size.to_s
      end

      ret = nil
      case kind
      when :GET
        ret = Net::HTTP::Get.new(path,header)
      when :POST
        ret = Net::HTTP::Post.new(path,header)
      when :PUT
        ret = Net::HTTP::Put.new(path,header)
      when :DELETE
        ret = Net::HTTP::Delete.new(path,header)
      else
        raise
      end

      ret.body = data if data

      ret
    end

    def self.get(server,port,path,secure=true)
      request(server,port,secure,gen_request(:GET,path))
    end

    def self.post(server,port,path,data,secure=true,content_type='application/json')
      request(server,port,secure,gen_request(:POST,path,data,content_type))
    end

    def self.put(server,port,path,data,secure=true,content_type='application/json')
      request(server,port,secure,gen_request(:PUT,path,data,content_type))
    end

    def self.delete(server,port,path,secure=true)
      request(server,port,secure,gen_request(:DELETE,path))
    end
  end
end

end
