# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

require 'socket'

module PortScanner
  # Test if a port is open
  #
  # Arguments
  # * hostname: hostname
  # * port: port
  # Output
  # * return true if the port is open, false otherwise
  def PortScanner::is_open?(hostname, port)
    begin
      s = TCPSocket.new(hostname,port)
      s.close
      return true
    rescue
      return false
    end
  end
end
