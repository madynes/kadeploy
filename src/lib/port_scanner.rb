# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

require 'socket'
require 'thread'

module PortScanner
  # Test if a port is open
  #
  # Arguments
  # * hostname: hostname
  # * port: port
  # Output
  # * return true if the port is open, false otherwise
  def PortScanner::is_open?(hostname, port)
    res = false
    tid = Thread.new {
      begin
        s = TCPSocket.new(hostname,port)
        s.close
        res = true
      rescue
        res = false
      end
    }
    start = Time.now.to_i
    while ((tid.status != false) && (Time.now.to_i < (start + 10)))
      sleep(0.05)
    end
    if (tid.status != false) then
      Thread.kill(tid)
      return false
    else
      return res
    end
  end

  # Test if a node accept or refuse connections on every ports of a list (TCP)
  def self.ports_test(nodeid, ports, accept=true)
    ret = true
    ports.each do |port|
      begin
        s = TCPsocket.open(nodeid, port)
        s.close
        unless accept
          ret = false
          break
        end
      rescue Errno::ECONNREFUSED
        if accept
          ret = false
          break
        end
      rescue Errno::EHOSTUNREACH
        ret = false
        break
      end
    end
    ret
  end
end
