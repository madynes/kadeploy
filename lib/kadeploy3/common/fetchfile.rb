require 'uri'
require 'fileutils'
require 'base64'
require 'digest/md5'

module Kadeploy

class FetchFile
  attr_reader :origin_uri

  def initialize(origin_uri,client=nil)
    @origin_uri = origin_uri
    @client = client
  end

  def self.[](origin_uri,client=nil)
    uri = URI.parse(origin_uri)
    kind = uri.scheme || 'local'
    case kind
    when 'local'
      fetcher = LocalFetchFile.new(uri.path,client)
    when 'server'
      fetcher = ServerFetchFile.new(uri.path,client)
    when 'http','https'
      fetcher = HTTPFetchFile.new(origin_uri,client)
    else
      raise KadeployError.new(
        APIError::INVALID_FILE,nil,
        "Unable to grab the file '#{origin_uri}', unknown protocol #{kind}"
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
    if File.readable?(@origin_uri)
      File.size(@origin_uri)
    else
      error("Unable to grab the file #{@origin_uri}")
    end
  end

  def checksum
    if File.readable?(@origin_uri)
      Digest::MD5.file(@origin_uri).hexdigest!
    else
      error("Unable to grab the file #{@origin_uri}")
    end
  end

  def mtime
    if File.readable?(@origin_uri)
      File.mtime(@origin_uri).to_i
    else
      error("Unable to grab the file #{@origin_uri}")
    end
  end

  def grab(dest,dir=nil)
    if File.readable?(@origin_uri)
      begin
        Execute['cp',@origin_uri,dest].run!.wait
      rescue Exception => e
        error("Unable to grab the file #{@origin_uri} (#{e.message})")
      end
    else
      error("Unable to grab the file #{@origin_uri}")
    end
  end
end

class HTTPFetchFile < FetchFile
  def initialize(origin_uri,client=nil)
    super(origin_uri,client)
    @file_status = nil
  end

  #Get file status when at first time.
  def get_file_status(uri)
    if @file_status
      @file_status
    else
      @file_status = HTTP.check_file(uri)
    end
  end
  def size
    begin
      get_file_status(@origin_uri)['content-length'][0].to_i
    rescue KadeployHTTPError => k
      error("Unable to get the size of #{@origin_uri} (http error ##{k.errno})")
    rescue Errno::ECONNREFUSED
      error("Unable to get the size of #{@origin_uri} (connection refused)")
    rescue KadeployError => ke
      raise ke
    rescue Exception => e
      error("Unable to grab the file #{@origin_uri} (#{e.message})")
    end
  end

  def checksum
    begin
      get_file_status(@origin_uri)['etag'][0]
    rescue KadeployHTTPError => k
      error("Unable to get the checksum of #{@origin_uri} (http error ##{k.errno})")
    rescue KadeployError => ke
      raise ke
    rescue Exception => e
      error("Unable to get the checksum of #{@origin_uri} (#{e.message})")
    end
  end

  def mtime
    begin
      Time.parse(get_file_status(@origin_uri)['last-modified'][0])
    rescue KadeployHTTPError => k
      error("Unable to get the mtime of #{@origin_uri} (http error ##{k.errno})")
    rescue KadeployError => ke
      raise ke
    rescue Errno::ECONNREFUSED
      error("Unable to get the mtime of #{@origin_uri} (connection refused)")
    rescue Exception => e
      error("Unable to grab the file #{@origin_uri} (#{e.message})")
    end
  end

  def grab(dest,dir=nil)
    begin
      HTTP.fetch_file(@origin_uri,dest)
      nil
    rescue KadeployHTTPError => k
      error("Unable to get the mtime of #{@origin_uri} (http error ##{k.errno})")
    rescue KadeployError => ke
      raise ke
    rescue Errno::ECONNREFUSED
      error("Unable to get the mtime of #{@origin_uri} (connection refused)")
    rescue Exception => e
      error("Unable to grab the file #{@origin_uri} (#{e.message})")
    end
  end
end

class LocalFetchFile < HTTPFetchFile
  def initialize(origin_uri,client=nil)
    super(origin_uri,client)
    raise KadeployError.new(APIError::INVALID_CLIENT,nil,'No client was specified') unless @client

    @origin_uri = File.join(@client.to_s,Base64.urlsafe_encode64(@origin_uri))
    begin
      URI.parse(@origin_uri)
      nil
    rescue
      raise KadeployError.new(APIError::INVALID_CLIENT,nil,'Invalid client origin_uri')
    end
  end
end

end
