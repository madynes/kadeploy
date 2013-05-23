require 'uri'
require 'fileutils'
require 'base64'

require 'http'
require 'md5'
require 'error'

class FetchFile
  def initialize(path,errno,client=nil)
    @path = path
    @errno = errno
    @client = client
  end

  def self.[](path,errno,client=nil)
    uri = URI.parse(path)
    kind = uri.scheme || 'local'
    case kind
    when 'local'
      fetcher = LocalFetchFile.new(uri.path,errno,client)
    when 'server'
      fetcher = ServerFetchFile.new(uri.path,errno,client)
    when 'http','https'
      fetcher = HTTPFetchFile.new(path,errno,client)
    else
      raise KadeployError.new(
        FetchFileError::UNKNOWN_PROTOCOL,nil,
        "Unable to grab the file '#{path}', unknown protocol #{kind}"
      )
    end
    fetcher
  end

  def error(errno,msg)
    raise KadeployError.new(errno,nil,msg)
  end

  def uptodate?(fchecksum,fmtime=nil)
    !((mtime != fmtime) and (checksum != fchecksum))
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
      error(@errno,"Unable to grab the file #{@path}")
    end
  end

  def checksum
    if File.readable?(@path)
      MD5::get_md5_sum(@path)
    else
      error(@errno,"Unable to grab the file #{@path}")
    end
  end

  def mtime
    if File.readable?(@path)
      File.mtime(@path).to_i
    else
      error(@errno,"Unable to grab the file #{@path}")
    end
  end

  def grab(dest,dir=nil)
    if File.readable?(@path)
      begin
        FileUtils.cp(@path,dest)
      rescue Exception => e
        error(@errno,"Unable to grab the file #{@path} (#{e.message})")
      end
    else
      error(@errno,"Unable to grab the file #{@path}")
    end
  end
end

class HTTPFetchFile < FetchFile
  def size
    begin
      HTTP::get_file_size(@path)
    rescue KadeployHTTPError => k
      error(@errno,"Unable to get the size of #{@path} (http error ##{k.errno})")
    rescue Errno::ECONNREFUSED
      error(@errno,"Unable to get the size of #{@path} (connection refused)")
    rescue KadeployError => ke
      raise ke
    rescue Exception => e
      error(@errno,"Unable to grab the file #{@path} (#{e.message})")
    end
  end

  def checksum
    begin
      HTTP.check_file(@path)['etag'][0]
    rescue KadeployHTTPError => k
      error(@errno,"Unable to get the checksum of #{@path} (http error ##{k.errno})")
    rescue KadeployError => ke
      raise ke
    rescue Exception => e
      error(@errno,"Unable to get the checksum of #{@path} (#{e.message})")
    end
  end

  def mtime
    begin
      HTTP::get_file_mtime(@path)
    rescue KadeployHTTPError => k
      error(@errno,"Unable to get the mtime of #{@path} (http error ##{k.errno})")
    rescue KadeployError => ke
      raise ke
    rescue Errno::ECONNREFUSED
      error(@errno,"Unable to get the mtime of #{@path} (connection refused)")
    rescue Exception => e
      error(@errno,"Unable to grab the file #{@path} (#{e.message})")
    end
  end

  def grab(dest,dir=nil)
    begin
      resp, _ = HTTP.fetch_file(@path,dest,dir,nil)
      case resp
      when -1
        error(FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE,
          "Tempfiles cannot be created")
      when -2
        error(FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE,
          "Environment file cannot be moved")
      when 200
        nil
      else
        error(@errno,"Unable to grab the file #{@path} (http error ##{resp})")
      end
    rescue KadeployError => ke
      raise ke
    rescue Exception => e
      error(@errno,"Unable to grab the file #{@path} (#{e.message})")
    end
  end
end

class LocalFetchFile < HTTPFetchFile
  def initialize(path,errno,client=nil)
    super(path,errno,client)
    @errno = errno
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
