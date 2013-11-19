require 'tempfile'
require 'net/http'
require 'net/https'
require 'uri'
require 'time'
require 'zlib'
require 'stringio'
require 'json'
require 'yaml'

module Kadeploy

module HTTP
  HTTP_TIMEOUT = 120

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
    attr_reader :code
    def initialize(msg,code=nil)
      super(msg)
      @code = code
    end
  end

  class Client
    def self.error(msg='',code=nil)
      raise ClientError.new(msg,code)
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
        client.read_timeout = HTTP_TIMEOUT
        yield(client)
      rescue Errno::ECONNREFUSED
        error("Connection atempt refused by the server")
      end
    end

    def self.request(server,port,secure=true,request=nil,parse=true)
      res = nil
      connect(server,port,secure) do |client|
        begin
          request = yield(client) unless request
          raise unless request.is_a?(Net::HTTPRequest)
          response = client.request(request)
        rescue Exception => e
          error("Invalid request on #{server}:#{port} (#{e.class.name})")
        end

        body = nil
        if response.content_length and response.content_length > 0 and response['Content-Encoding'] == 'gzip'
          sio = StringIO.new(response.body,'rb')
          gzr = Zlib::GzipReader.new(sio)
          body = gzr.read
          gzr.close
        else
          body = response.body
        end

        if response.is_a?(Net::HTTPOK)

          if parse
            case response['Content-Type'].split(';').first.downcase
            when 'application/json'
              res = JSON::load(body)
            when 'application/x-yaml'
              res = YAML::load(body)
            when 'text/csv'
              res = body
            when 'text/plain'
              res = body
            else
              error("Invalid server response (Content-Type: '#{response['Content-Type']}')")
            end
          else
            res = body
          end
        else
          case response.code.to_i
          when 400
            if response['X-Application-Error-Code']
              error("[Kadeploy Error ##{response['X-Application-Error-Code']}]\n#{body}",(response['X-Application-Error-Code'].to_i rescue 1))
            else
              error(
                "[HTTP Error ##{response.code} on #{request.method} #{request.path}]\n"\
                "-----------------\n"\
                "#{body}\n"\
                "-----------------"
              )
            end
          when 500
            error("[Internal Server Error]\n#{body}")
          else
            error(
              "[HTTP Error ##{response.code} on #{request.method} #{request.path}]\n"\
              "-----------------\n"\
              "#{body}\n"\
              "-----------------"
            )
          end
        end
      end
      res
    end

    def self.content_type(kind)
      case kind
        when :json
          'application/json'
        when :yaml
          'application/x-yaml'
        else
          raise
      end
    end

    def self.content_cast(kind,obj)
      case kind
        when :json
          obj.to_json
        when :yaml
          obj.to_yaml
        else
          raise
      end
    end

    def self.gen_request(kind,path,data=nil,content_type=:json,accept_type=:json)
      header = { 'Accept' => content_type(accept_type) }
      if data
        data = content_cast(content_type,data)
        header['Content-Type'] = content_type(content_type)
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

    def self.get(server,port,path,secure=true,content_type=:json,accept_type=:json,parse=true)
      request(server,port,secure,gen_request(:GET,path,nil,nil,accept_type),parse)
    end

    def self.post(server,port,path,data,secure=true,content_type=:json,accept_type=:json,parse=true)
      request(server,port,secure,gen_request(:POST,path,data,content_type,accept_type),parse)
    end

    def self.put(server,port,path,data,secure=true,content_type=:json,accept_type=:json,parse=true)
      request(server,port,secure,gen_request(:PUT,path,data,content_type,accept_type),parse)
    end

    def self.delete(server,port,path,secure=true,content_type=:json,accept_type=:json,parse=true)
      request(server,port,secure,gen_request(:DELETE,path,nil,nil,accept_type),parse)
    end
  end
end

end
