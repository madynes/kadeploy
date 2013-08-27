require 'ipaddr'
require 'resolv'
require 'timeout'
require 'socket'
require 'openssl'

module Kadeploy

class Authentication
  UNTRUSTED_SOURCE='Trying to authenticate from an untrusted source'
  INVALID_PARAMS='Invalid authentication parameters'

  attr_reader :whitelist

  def initialize()
    @whitelist = []
  end

  def check_host?(source_sock)
    if @whitelist.empty?
      true
    else
      ret = false
      ip = source_sock[3]
      @whitelist.each do |host|
        if host.is_a?(IPAddr)
          # IP is in the whitelist / is included in one of the whitelist nets
          if host.include?(IPAddr.new(ip))
            ret = true
            break
          end
        elsif host.is_a?(Regexp)
          begin
            if host =~ Resolv.getname(ip)
              ret = true
              break
            end
          rescue Resolv::ResolvError
          end
        else
          raise
        end
      end
      ret
    end
  end

  def auth!(source_sock,params={})
    raise
  end
end

class SecretKeyAuthentication < Authentication
  def initialize(secret_key)
    super()
    @secret_key = secret_key.freeze
  end

  def auth!(source_sock,params={})
    return [false,UNTRUSTED_SOURCE] unless check_host?(source_sock)

    [params[:key] == @secret_key,"#{INVALID_PARAMS} '#{params[:key]}'"]
  end
end

class CertificateAuthentication < Authentication
  def initialize(ca_public_key)
    super()
    @public_key = ca_public_key
  end

  def auth!(source_sock,params={})
    return [false,UNTRUSTED_SOURCE] unless check_host?(source_sock)

    [params[:cert].verify(@public_key),INVALID_PARAMS]
  end
end

class IdentAuthentication < Authentication
  def auth!(source_sock,params={})
    return [false,UNTRUSTED_SOURCE] unless check_host?(source_sock)

    source = { :ip => source_sock[3], :port => source_sock[1] }
    ident = nil
    begin
      Timeout::timeout(10) do
        sock = TCPSocket.new(source[:ip],113)
        sock.puts("#{source[:port]}, #{params[:port]}")
        ident = sock.gets.strip
        sock.close
      end
    rescue Timeout::Error
      return [false, 'Connection to ident service timed out']
    rescue Errno::ECONNREFUSED
      return [false, 'Connection to ident service was refused']
    rescue Exception
      return [false, 'Connection to ident service failed']
    end

    user = nil
    # 12345, 443 : USERID : UNIX : username
    # or
    # 12345, 443 : ERROR : NO-USER
    # ...
    if /^\s*\d+\s*,\s*\d+\s*:\s*(\S+)\s*:\s*(\S+)\s*(?::\s*(\S+)\s*)$/ =~ ident
      res = Regexp.last_match(1)
      dom = Regexp.last_match(2)
      usr = Regexp.last_match(3)
      if res.upcase == 'USERID'
        user = usr
      else
        return [false,"Ident authentication failed: #{dom||res}"]
      end
    else
      return [false,'Ident authentication failed, invalid answer from service']
    end

    [user == params[:user],'Specified user does not match with the one given by the ident service']
  end
end

end
