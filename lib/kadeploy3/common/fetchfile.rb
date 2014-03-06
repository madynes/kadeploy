require 'uri'
require 'fileutils'
require 'base64'
require 'digest/md5'

module Kadeploy

class FetchFile
  attr_reader :path

  def initialize(path,client=nil)
    @path = path
    @client = client
  end

  def self.[](path,client=nil)
    uri = URI.parse(path)
    kind = uri.scheme || 'local'
    case kind
    when 'local'
      fetcher = LocalFetchFile.new(uri.path,client)
    when 'server'
      fetcher = ServerFetchFile.new(uri.path,client)
    when 'http','https'
      fetcher = HTTPFetchFile.new(path,client)
    else
      raise KadeployError.new(
        APIError::INVALID_FILE,nil,
        "Unable to grab the file '#{path}', unknown protocol #{kind}"
      )
    end
    fetcher
  end

  def error(msg,errno=nil)
    raise KadeployError.new(errno||APIError::INVALID_FILE,nil,msg)
  end

  def uptodate?(fchecksum,fmtime=nil)
    !((mtime > fmtime) and (checksum != fchecksum))
  end

  def size
    raise 'Should be reimplemented'
  end

  def checksum
    raise 'Should be reimplemented'
  end

  def mtime
    raise 'Should be reimplemented'
  end

  def grab(dest,dir=nil)
    raise 'Should be reimplemented'
  end
end

class ServerFetchFile < FetchFile
  def size
    if File.readable?(@path)
      File.size(@path)
    else
      error("Unable to grab the file #{@path}")
    end
  end

  def checksum
    if File.readable?(@path)
      Digest::MD5.file(@path).hexdigest!
    else
      error("Unable to grab the file #{@path}")
    end
  end

  def mtime
    if File.readable?(@path)
      File.mtime(@path).to_i
    else
      error("Unable to grab the file #{@path}")
    end
  end

  def grab(dest,dir=nil)
    if File.readable?(@path)
      begin
        FileUtils.cp(@path,dest)
      rescue Exception => e
        error("Unable to grab the file #{@path} (#{e.message})")
      end
    else
      error("Unable to grab the file #{@path}")
    end
  end
end

class HTTPFetchFile < FetchFile
  def size
    begin
      HTTP::get_file_size(@path)
    rescue KadeployHTTPError => k
      error("Unable to get the size of #{@path} (http error ##{k.errno})")
    rescue Errno::ECONNREFUSED
      error("Unable to get the size of #{@path} (connection refused)")
    rescue KadeployError => ke
      raise ke
    rescue Exception => e
      error("Unable to grab the file #{@path} (#{e.message})")
    end
  end

  def checksum
    begin
      HTTP.check_file(@path)['etag'][0]
    rescue KadeployHTTPError => k
      error("Unable to get the checksum of #{@path} (http error ##{k.errno})")
    rescue KadeployError => ke
      raise ke
    rescue Exception => e
      error("Unable to get the checksum of #{@path} (#{e.message})")
    end
  end

  def mtime
    begin
      HTTP::get_file_mtime(@path)
    rescue KadeployHTTPError => k
      error("Unable to get the mtime of #{@path} (http error ##{k.errno})")
    rescue KadeployError => ke
      raise ke
    rescue Errno::ECONNREFUSED
      error("Unable to get the mtime of #{@path} (connection refused)")
    rescue Exception => e
      error("Unable to grab the file #{@path} (#{e.message})")
    end
  end

  def grab(dest,dir=nil)
    begin
      if (code = HTTP.fetch_file(@path,dest)) != 200
        error("Unable to grab the file #{@path} (http error ##{code})")
      end
      nil
    rescue Exception => e
      error("Unable to grab the file #{@path} (#{e.message})")
    end
  end
end

class LocalFetchFile < HTTPFetchFile
  def initialize(path,client=nil)
    super(path,client)
    raise KadeployError.new(APIError::INVALID_CLIENT,nil,'No client was specified') unless @client

    @path = File.join(@client.to_s,Base64.urlsafe_encode64(@path))
    begin
      URI.parse(@path)
      nil
    rescue
      raise KadeployError.new(APIError::INVALID_CLIENT,nil,'Invalid client path')
    end
  end
end

end
