LOGFILE_HTTPD='httpd.log'
LOGFILE_ACCESS='access.log'
MAX_CLIENTS = 1000

require 'webrick'
require 'webrick/https'
require 'webrick/httpservlet/abstract'
require 'socket'
require 'base64'

include WEBrick

class MethodHandler < WEBrick::HTTPServlet::AbstractServlet
  def get_instance(server, *options)
    self
  end

  def initialize(proc)
    @proc = proc
  end

  def do_METHOD(request, response)
    # No caching
    response['ETag'] = nil
    response['Cache-Control'] = 'no-store, no-cache'
    response['Pragma'] = 'no-cache'
    @proc.call(request, response)
  end

  alias do_HEAD do_METHOD
  alias do_GET do_METHOD
  alias do_POST do_METHOD
  alias do_DELETE do_METHOD
end

class HTTPd
  attr_reader :host, :port, :logs
  def initialize(host='',port=0,secure=true,httpd_logfile=nil)
    @host = host || ''
    @port = port || 0
    @secure = secure

    @logs = {}
    if httpd_logfile
      @logs[:httpd] = File.open(File.join(httpd_logfile),'a+')
    elsif $kadeploy_logdir
      @logs[:httpd] = File.open(File.join($kadeploy_logdir,LOGFILE_HTTPD),'a+')
    end

    if $kadeploy_logdir
      @logs[:access] = File.open(File.join($kadeploy_logdir,LOGFILE_ACCESS),'a+')
      @logs[:access].sync = true
    end

    opts = {
      :Port => @port,
      :DocumentRoot => nil,
      :DocumentRootOptions => nil,
      :MaxClients => MAX_CLIENTS,
      :DoNotReverseLookup => true,
    }

    if @logs[:httpd]
      opts[:Logger] = WEBrick::Log.new(@logs[:httpd])
    else
      opts[:Logger] = WEBrick::Log.new('/dev/null')
    end

    if @logs[:access]
      opts[:AccessLog] = [
        [
          @logs[:access],
          WEBrick::AccessLog::COMMON_LOG_FORMAT
        ]
      ]
    else
      opts[:AccessLog] = []
    end

    if secure
      opts[:SSLEnable] = true,
      opts[:SSLCertName] = [['CN',@host]]
      opts[:SSLVerifyClient] = OpenSSL::SSL::VERIFY_NONE
    end

    @server = HTTPServer.new(opts)
    @host = @server.config[:ServerName] if @host.empty?
    @port = @server.config[:Port] if @port == 0
  end

  def kill()
    @server.shutdown()
  end

  def run()
    @server.start()
  end

  def url()
    "http#{'s' if @secure}://#{@host}:#{@port}"
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
              if res.is_a?(String)
                response['Content-Type'] = 'text/plain'
              else
                res = res.to_json
                response['Content-Type'] = 'application/json'
              end
            elsif obj.is_a?(Hash) or obj.is_a?(Array)
              res = obj
              res = res.to_json
              response['Content-Type'] = 'application/json'
            elsif block_given?
              res = yield(request,method)
              if res.is_a?(String)
                response['Content-Type'] = 'text/plain'
              else
                res = res.to_json
                response['Content-Type'] = 'application/json'
              end
            elsif obj.is_a?(File)
              res = obj
              response['Content-Type'] = 'application/octet-stream'
            else
              raise
            end
            response.status = 200
          rescue KadeployError => ke
            res = KadeployError.to_msg(ke.errno)
            res += " -- #{ke.message}" if ke.message and !ke.message.empty?
            response.status = 400
            response['Content-Type'] = 'text/plain'
            response['X-Application-Error-Code'] = ke.errno
            response['X-Application-Error-Info'] = Base64.strict_encode64(res)
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
          response['Allow'] = methods.collect{|m|m.to_s}.join(',')
          res = 'Method Not Allowed'
        end
        response['Content-Length'] = res.size
        response.body = res unless method == :HEAD
        res = nil
      end
    ))
  end

  def unbind(path)
    @server.umount(path)
  end
end
