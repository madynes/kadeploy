LOGFILE_HTTPD='httpd.log'
LOGFILE_ACCESS='access.log'
MAX_CLIENTS = 1000

require 'webrick'
require 'webrick/https'
require 'webrick/httpservlet/abstract'
require 'socket'
require 'base64'

include WEBrick

class HTTPdInvalidError < Exception
end

class ContentBinding < Hash
end

class HTTPdHandler < WEBrick::HTTPServlet::AbstractServlet
  def initialize(allowed_methods)
    @types = nil
    if allowed_methods.is_a?(Array)
      @allowed = allowed_methods.collect{|m| m.to_s.upcase.to_sym}
    elsif allowed_methods.is_a?(Hash)
      @allowed = []
      @types = {}
      allowed_methods.each_pair do |method,type|
        method = method.to_s.upcase.to_sym
        @allowed << method
        @types[method] = type
      end
    elsif allowed_methods.is_a?(Symbol)
      @allowed = [allowed_methods.to_s.upcase.to_sym]
    else
      raise
    end
    #[:HEAD, :GET, :POST, :DELETE].each do |m|
    #  if @allowed.include?(m)
    #    class_eval "alias :\"do_#{m.to_s.upcase}\", :do_METHOD"
    #  else
    #    class_eval "alias :\"do_#{m.to_s.upcase}\", :do_INVALID"
    #  end
    #end
  end

  def get_instance(server, *options)
    self
  end

  def get_method(request)
    request.request_method.upcase.to_sym
  end

  def do_METHOD(request, response)
    if @allowed.include?(get_method(request))
      begin
        if !@types or (request['Content-Type']||'') == @types[get_method(request)]
          # No caching
          response['ETag'] = nil
          response['Cache-Control'] = 'no-store, no-cache'
          response['Pragma'] = 'no-cache'

          res = handle(request,response)

          response.status = 200
          if res.is_a?(String)
            response['Content-Type'] = 'text/plain'
          elsif res.nil?
            res = ''
            response['Content-Type'] = 'text/plain'
          elsif res.is_a?(File)
            response['Content-Type'] = 'application/octet-stream'
          else
            res = res.to_json
            response['Content-Type'] = 'application/json'
          end
        else
          res = 'Unsupported Media Type'
          response.status = 415
          response['Content-Type'] = 'text/plain'
        end
      rescue HTTPdInvalidError
        res = 'Method Not Allowed'
        response.status = 405
        response['Content-Type'] = 'text/plain'
        response['Allow'] = @allowed.collect{|m|m.to_s}.join(',')
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
      res = 'Method Not Allowed'
      response.status = 405
      response['Content-Type'] = 'text/plain'
      response['Allow'] = (@allowed + [:HEAD]).collect{|m|m.to_s}.join(',')
    end
    response['Content-Length'] = res.size
    response.body = res unless get_method(request) == :HEAD
    res = nil
  end

  def handle(request, response)
    raise
  end

  alias_method :do_HEAD, :do_METHOD
  alias_method :do_GET, :do_METHOD
  alias_method :do_POST, :do_METHOD
  alias_method :do_PUT, :do_METHOD
  alias_method :do_DELETE, :do_METHOD
end

class ProcedureHandler < HTTPdHandler
  def initialize(allowed_methods,proc)
    super(allowed_methods)
    @proc = proc
  end

  def handle(request, response)
    @proc.call(get_method(request),request)
  end
end

class MethodHandler < HTTPdHandler
  # Call a method with static or dynamic args
  def initialize(allowed_methods,obj,method,args=nil)
    super(allowed_methods)
    @obj = obj
    @method = method
    @args = args
  end

  def handle(request, response)
    # if no static args, the args are the different elements of the path
    args = nil
    if @args
      if @args.is_a?(ContentBinding)
        args = @args[get_method(request)]
      else
        args = @args
      end
    else
      # Ignore the first element
      # TODO: Do something better
      args = request.request_uri.path.split('/')[2..-1]
    end
    args = [args] unless args.is_a?(Array)

    begin
      if @method.is_a?(ContentBinding)
        @obj.send(@method[get_method(request)].to_s.to_sym,*args)
      else
        @obj.send(@method.to_s.to_sym,*args)
      end
    rescue ArgumentError
      raise HTTPdInvalidError.new
    end
  end
end

class ContentHandler < HTTPdHandler
  # if dyn is specified will return contents[HTTP_METHOD]
  def initialize(allowed_methods,content)
    super(allowed_methods)
    @content = content
  end

  def handle(request, response)
    if @content.is_a?(ContentBinding)
      @content[get_method(request)]
    else
      @content
    end
  end
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

  # :object, args and method => :method_name or { :GET => :method1, :POST => :method2 }
  # :content :value => {},123,[],... or { :GET => 123, :POST => 'abc' }
  def bind(methods,path,kind=:proc,params={},&block)#obj=nil,meth=nil,*params)
puts "BIND #{path}"
    methods = [methods] if methods.is_a?(Symbol)
    case kind
    when :method
      raise unless params.is_a?(Hash) and params[:object] and params[:method]
      @server.mount(path,MethodHandler.new(methods,params[:object],params[:method],params[:args]))
    when :content
      @server.mount(path,ContentHandler.new(methods,params))
    when :file
      @server.mount(path,ContentHandler.new(methods,params))
    when :proc
      if block_given?
        @server.mount(path,ProcedureHandler.new(methods,block))
      else
        @server.mount(path,ProcedureHandler.new(methods,params))
      end
    else
      raise
    end
=begin
# TODO: Use MethodHandler
    @server.mount(path,ProcedureHandler.new(
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
              elsif res.nil?
                res = ''
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
=end
  end

  def unbind(path)
    @server.umount(path)
  end
end
