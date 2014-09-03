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
  def self.fetch_file(uri,destfile)
    ret = nil
    url = URI.parse(uri)
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = url.is_a?(URI::HTTPS)
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.start
    http.request_get(url.path,{}) do |resp|
      raise KadeployHTTPError.new(resp.code) if !resp.is_a?(Net::HTTPSuccess) and !resp.is_a?(Net::HTTPNotModified)

      ret = resp.to_hash
      File.open(destfile,'w+') do |f|
        resp.read_body do |chunk|
          f.write chunk
          nil
        end
      end
    end

    return ret
  end

  def self.check_file(uri)
    url = URI.parse(uri)
    resp = nil
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = url.is_a?(URI::HTTPS)
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.start
    resp = http.head(url.path,{})
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

    def self.request(server,port,secure=true,request=nil,parse=nil)
      parse = true if parse.nil?
      res = nil
      connect(server,port,secure) do |client|
        begin
          request = yield(client) unless request
          raise unless request.is_a?(Net::HTTPRequest)
          response = client.request(request)
        rescue Exception => e
          error("Invalid request on #{server}:#{port} (#{e.message})")
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
            begin
              tmp = response['Content-Type'].split(';').first.downcase
            rescue Exception
              tmp = ''
            end

            case tmp
            when 'application/json'
              res = JSON::load(body)
            when 'application/x-yaml'
              res = YAML::load(body)
            when 'text/csv'
              res = body
            when 'text/plain'
              res = body
            else
              error("Invalid server response (Content-Type: '#{response['Content-Type']}')\n#{body if body}")
            end
          else
            res = body
          end
        else
          case response.code.to_i
          when 400
            if response['X-Application-Error-Code']
              error("#{body.strip}\n"\
                "[Kadeploy Error ##{response['X-Application-Error-Code']}]",
                (response['X-Application-Error-Code'].to_i rescue 1))
            else
              error("#{body.strip}\n"\
                "[HTTP Error ##{response.code} on #{request.method} #{request.path}]",2)
            end
          when 404
            error("Resource not found #{request.path.split('?').first}")
          when 500
            error("[Internal Server Error]\n#{body.strip}",3)
          else
            error("#{body.strip}\n"\
              "[HTTP Error ##{response.code} on #{request.method} #{request.path}]",2)
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

    def self.gen_request(kind,path,data=nil,content_type=nil,accept_type=nil,headers=nil)
      content_type ||= :json
      accept_type ||= :json

      header = { 'Accept' => content_type(accept_type) }
      if data
        data = content_cast(content_type,data)
        header['Content-Type'] = content_type(content_type)
        header['Content-Length'] = data.size.to_s
      end
      header.merge!(headers) if headers

      ret = nil
      case kind
      when :GET
        ret = Net::HTTP::Get.new(path,header)
      when :HEAD
        ret = Net::HTTP::Head.new(path,header)
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
      ret.basic_auth($http_user,$http_password) if $http_user and $http_password

      ret
    end

    def self.get(server,port,path,secure=true,content_type=nil,accept_type=nil,parse=nil,headers=nil)
      request(server,port,secure,gen_request(:GET,path,nil,nil,accept_type,headers),parse)
    end

    def self.post(server,port,path,data,secure=true,content_type=nil,accept_type=nil,parse=nil,headers=nil)
      request(server,port,secure,gen_request(:POST,path,data,content_type,accept_type,headers),parse)
    end

    def self.put(server,port,path,data,secure=true,content_type=nil,accept_type=nil,parse=nil,headers=nil)
      request(server,port,secure,gen_request(:PUT,path,data,content_type,accept_type,headers),parse)
    end

    def self.delete(server,port,path,data,secure=true,content_type=nil,accept_type=nil,parse=nil,headers=nil)
      request(server,port,secure,gen_request(:DELETE,path,data,content_type,accept_type,headers),parse)
    end
  end
end

end
