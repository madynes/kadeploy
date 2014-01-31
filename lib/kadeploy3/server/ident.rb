require 'socket'

module Kadeploy

class IdentError < Exception
end

class Ident
  def self.userid(sock,port)
    source = { :ip => sock[3], :port => sock[1] }

    ident = nil
    begin
      Timeout::timeout(10) do
        sock = TCPSocket.new(source[:ip],113)
        sock.puts("#{source[:port]}, #{port}")
        ident = sock.gets.strip
        sock.close
      end
    rescue Timeout::Error
      raise IdentError, 'Connection to ident service timed out'
    rescue Errno::ECONNREFUSED
      raise IdentError, 'Connection to ident service was refused'
    rescue Exception => e
      raise IdentError, "Connection to ident service failed (#{e.class.name}: #{e.message})"
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
        raise IdentError, "Ident authentication failed: #{dom||res}"
      end
    else
      raise IdentError, 'Ident authentication failed, invalid answer from service'
    end

    user
  end
end

end
