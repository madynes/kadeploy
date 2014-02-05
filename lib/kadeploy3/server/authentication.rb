require 'ipaddr'
require 'resolv'
require 'timeout'
require 'openssl'
require 'webrick'

module Kadeploy

class Authentication
  UNTRUSTED_SOURCE='Trying to authenticate from an untrusted source'
  INVALID_PARAMS='Invalid authentication credentials'

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

class ACLAuthentication < Authentication
  def auth!(source_sock,params={})
    return [check_host?(source_sock),UNTRUSTED_SOURCE]
  end

  def ==(auth)
    if auth.is_a?(self.class)
      @whitelist == auth.whitelist
    else
      false
    end
  end
end

class HTTPBasicAuthentication < Authentication
  attr_reader :realm

  def initialize(dbfile,realm)
    super()
    @dbfile = dbfile
    @realm = realm.freeze
    @authenticator = WEBrick::HTTPAuth::BasicAuth.new({
      :Realm => @realm,
      :UserDB => @dbfile,
      :AutoReloadUserDB => true,
    })
  end

  def auth!(source_sock,params={})
    return [false,UNTRUSTED_SOURCE] unless check_host?(source_sock)

    ret = nil
    begin
      @authenticator.authenticate(params[:req],{})
      ret = true
    rescue
      ret = false
    end
    [ret,INVALID_PARAMS]
  end

  def ==(auth)
    if auth.is_a?(self.class)
      (@dbfile.instance_variable_get(:@path) == auth.instance_variable_get(:@dbfile).instance_variable_get(:@path) and @realm == auth.realm and @whitelist == auth.whitelist)
    else
      false
    end
  end
end

class CertificateAuthentication < Authentication
  def initialize(ca_public_key)
    super()
    @public_key = ca_public_key
  end

  def auth!(source_sock,params={})
    return [false,UNTRUSTED_SOURCE] unless check_host?(source_sock)

    cert = nil
    begin
      cert = OpenSSL::X509::Certificate.new(params[:cert])
    rescue Exception => e
      return [false,"Invalid x509 certificate (#{e.message})"]
    end

    cns = nil
    if cert.verify(@public_key)
      cns = cert.subject.to_a.select{|v| v[0] == 'CN'}.collect{|v| v[1]}
    else
      return [false,"The certificate was not signed by the trusted CA"]
    end

    if params[:user]
      [cns.include?(params[:user]),'Specified user does not match with the certificate\'s CN']
    else
      [cns.first,nil]
    end
  end

  def ==(auth)
    if auth.is_a?(self.class)
      (@public_key.to_der == auth.instance_variable_get(:@public_key).to_der and @whitelist == auth.whitelist)
    else
      false
    end
  end
end

class IdentAuthentication < Authentication
  def auth!(source_sock,params={})
    return [false,UNTRUSTED_SOURCE] unless check_host?(source_sock)

    user = nil
    begin
      user = Ident.userid(source_sock,params[:port])
    rescue IdentError => ie
      return [false, ie.message]
    end

    if params[:user]
      [user == params[:user],'Specified user does not match with the one given by the ident service']
    else
      [user,nil]
    end
  end

  def ==(auth)
    if auth.is_a?(self.class)
      @whitelist == auth.whitelist
    else
      false
    end
  end
end

end
