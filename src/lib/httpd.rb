LOGFILE_HTTPD='httpd.log'
LOGFILE_ACCESS='access.log'
MAX_CLIENTS = 1000

require 'webrick'
require 'webrick/https'
require 'webrick/httpservlet/abstract'
require 'socket'

include WEBrick

class MethodHandler < WEBrick::HTTPServlet::AbstractServlet
  def get_instance(server, *options)
    self
  end

  def initialize(proc)
    @proc = proc
  end

  def do_METHOD(request, response)
    @proc.call(request, response)
  end

  alias do_GET do_METHOD
  alias do_POST do_METHOD
  alias do_DELETE do_METHOD
end

class HTTPd
  attr_reader :host, :port, :logs
  def initialize(host,port)
    @host = host
    @port = port
    @logs = {
      :httpd => File.open(File.join($kadeploy_logdir,LOGFILE_HTTPD), 'a+'),
      :access =>File.open(File.join($kadeploy_logdir,LOGFILE_ACCESS), 'a+'),
    }
    @logs[:access].sync = true

    @server = HTTPServer.new(
      :Port=>@port,
      :DocumentRoot=>nil,
      :DocumentRootOptions => nil,
      :MaxClients => MAX_CLIENTS,
      :DoNotReverseLookup => true,
      :SSLEnable => true,
      :SSLCertName => [['CN',@host]],
      :SSLVerifyClient  => OpenSSL::SSL::VERIFY_NONE,
      :Logger => WEBrick::Log.new(@logs[:httpd]),
      :AccessLog => [
        [
          @logs[:access],
          WEBrick::AccessLog::COMMON_LOG_FORMAT
        ]
      ]
    )
  end

  def kill()
    @server.shutdown()
  end

  def run()
    @server.start()
  end

  def bind(methods,path,obj=nil,meth=nil,*params)
    @server.mount(path,MethodHandler.new(
      Proc.new do |request,response|
        res = ''
        method = request.request_method.upcase.to_sym
        if methods.include?(method)
          begin
            if obj and meth
              res = obj.send(meth.to_sym,*params)
            elsif obj.is_a?(Hash) or obj.is_a?(Array)
              res = obj
            elsif block_given?
              res = yield(request,method)
            else
              raise
            end
            res = res.to_json
            response.status = 200
            response['Content-Type'] = 'application/json'
          rescue KadeployError => ke
            res = KadeployError.to_msg(ke.errno)
            res += "\n#{ke.message}" if ke.message and !ke.message.empty?
            response.status = 400
            response['Content-Type'] = 'text/plain'
            response['X-Application-Error-Code'] = ke.errno
            response['X-Application-Error-Info'] = res
          rescue Exception => e
            res = "---- #{e.class.name} ----\n"\
              "#{e.message}\n"\
              "---- Stack trace ----\n"\
              "#{e.backtrace.join("\n")}\n"\
              "---------------------"
            response.status = 500
            response['Content-Type'] = 'text/plain'
          end
        else
          response.status = 405
          response['Content-Type'] = 'text/plain'
          res = 'Method Not Allowed'
        end
        response['Content-Length'] = res.size
        response.body = res
        res = nil
      end
    ))
  end

  def unbind(path)
    @server.umount(path)
  end
end
