LOGFILE_HTTPD='httpd.log'
LOGFILE_ACCESS='access.log'
MAX_CLIENTS = 1000

require 'webrick'
require 'webrick/https'
require 'webrick/httpservlet/abstract'
require 'socket'
require 'base64'
require 'cgi'

require 'json'

include WEBrick

module HTTPd
  class InvalidError < Exception
  end
  class NotFoundError < Exception
  end
  class UnauthorizedError < Exception
  end
  class ForbiddenError < Exception
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

    def get_remote_port(request)
      request.instance_variable_get(:@peeraddr)[1]
    end

    def do_METHOD(request, response)
      if @allowed.include?(get_method(request))
        begin
          if !@types or !@types[get_method(request)] or (request['Content-Type']||'') == @types[get_method(request)]
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
            elsif res.is_a?(TrueClass)
              res = 'true'
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
        rescue UnauthorizedError
          res = 'Unauthorized'
          response.status = 401
          response['Content-Type'] = 'text/plain'
        rescue ForbiddenError
          res = 'Forbidden'
          response.status = 403
          response['Content-Type'] = 'text/plain'
        rescue NotFoundError
          res = 'File not found'
          response.status = 404
          response['Content-Type'] = 'text/plain'
        rescue InvalidError
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
    def initialize(allowed_methods,obj,method,args=nil,blocks=nil)
      super(allowed_methods)
      @obj = obj
      @method = method
      @args = args
      @blocks = blocks
    end

    def handle(request, response)
      args = nil
      if @args.is_a?(ContentBinding)
        args = @args[get_method(request)]
      else
        args = @args
      end
      args = [] if args.nil?
      args = [args] unless args.is_a?(Array)

      name = nil
      if @method.is_a?(ContentBinding)
        name = @method[get_method(request)].to_s.to_sym
      else
        name = @method.to_s.to_sym
      end
      begin
        @obj.send(name,*args,&proc{request})
      rescue ArgumentError => e
      # if the problem is that the method is called with the wrong nb of args
        if e.backtrace[0].split(/\s+/)[-1] =~ /#{kind}_get/ \
        and e.message =~ /wrong number of arguments/
          raise NotFoundError.new
        else
          raise e
        end
      rescue NoMethodError => e
      # if the problem is that the method does not exists
        if e.name == name
          raise NotFoundError.new
        else
          raise e
        end
      end
      # Errors in the number of arguments and name are treaten elsewhere
    end
  end

  class MethodFilterHandler < MethodHandler
    def initialize(allowed_methods,obj,method,filter,names=nil)
      super(allowed_methods,obj,method,nil)
      @obj = obj
      @method_prefix = method
      @filter = filter
      @names = names
    end

    def handle(request, response)
      filter = nil
      @args = []
      if @filter.is_a?(ContentBinding)
        filter = @filter[get_method(request)]
      elsif @filter.is_a?(Hash)
        filter = @filter[:dynamic] || []
        @args += @filter[:static] if @filter[:static]
      else
        filter = @filter
      end
      names = nil
      if @names.is_a?(ContentBinding)
        names = @names[get_method(request)]
      else
        names = @names
      end
      names = [] unless names
      prefix = nil
      if @method_prefix.is_a?(ContentBinding)
        prefix = @method_prefix[get_method(request)]
      else
        prefix = @method_prefix
      end

      fields = request.request_uri.path.split('/')[1..-1]
      @args += fields.values_at(*filter).compact
      suffix = fields.values_at(*names).compact
      if suffix.empty?
        @method = prefix.to_sym
      else
        @method = (prefix.to_s + '_' + suffix.join('_')).to_sym
      end
      super(request, response)
    end
  end

  class ContentHandler < HTTPdHandler
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

  def self.parse_params(request,firstonly=true)
    ret = CGI.parse(request.request_uri.query||'')
    ret.inject({}) { |h, (k, v)| h[k] = v[0]; h } if firstonly
  end

  def self.parse_body(request,type)
    case type
    when :json
      begin
        JSON::load(request.body)
      rescue JSON::ParserError
      end
    end
  end

  class Server
    attr_reader :host, :port, :logs
    def initialize(host='',port=0,secure=true,httpd_logfile=nil)
      @host = host || ''
      @port = port || 0
      @secure = secure

      # Check logs directory
      if !File.directory?($kadeploy_logdir)
        self.class.error("Log directory '#{$kadeploy_logdir}' does not exists")
      end

      if (!File.writable?(File.join($kadeploy_logdir,LOGFILE_HTTPD)) \
          or !File.writable?(File.join($kadeploy_logdir,LOGFILE_ACCESS))) \
        and !File.writable?($kadeploy_logdir)
        self.class.error("Log directory '#{$kadeploy_logdir}' not writable")
      end

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

    def self.error(msg='',abrt = true)
      $stderr.puts msg if msg and !msg.empty?
      exit 1 if abrt
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
    def bind(methods,path,kind=:proc,params={},&block)
  puts "BIND #{kind} #{path}"
      methods = [methods] if methods.is_a?(Symbol)
      case kind
      when :method
        raise unless params.is_a?(Hash) and params[:object] and params[:method]
        @server.mount(path,MethodHandler.new(methods,params[:object],params[:method],params[:args]))
      when :filter
        raise unless params.is_a?(Hash) and params[:object] and params[:method] and params[:args]
        @server.mount(path,MethodFilterHandler.new(methods,params[:object],params[:method],params[:args],params[:name]))
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
    end

    def unbind(path)
  puts "UNBIND #{path}"
      @server.umount(path)
    end
  end
end
