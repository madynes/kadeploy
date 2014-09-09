require 'webrick'
require 'webrick/https'
require 'webrick/httpservlet/abstract'
require 'socket'
require 'base64'
require 'cgi'
require 'time'
require 'zlib'
require 'stringio'
require 'json'
require 'yaml'

if RUBY_VERSION < "2.0"
  # Monkey patch to remove DH encryption related warnings
  class WEBrick::GenericServer
    alias_method :__setup_ssl_context__, :setup_ssl_context

    def setup_ssl_context(config)
      ctx = __setup_ssl_context__(config)
      ctx.tmp_dh_callback = config[:SSLTmpDhCallback] if ctx && ctx.respond_to?(:tmp_dh_callback)
      ctx
    end
  end
end

module Kadeploy

module HTTPd
  LOGFILE_HTTPD='httpd.log'
  LOGFILE_ACCESS='access.log'
  MAX_CLIENTS = 1000
  MAX_CONTENT_SIZE = 1048576 # 1 MB
  SERVLET_TIMEOUT = 600 #10 min

  class HTTPError < Exception
    attr_reader :code,:headers
    def initialize(code,name,msg=nil,headers=nil)
      super(msg)
      @code = code
      @name = name
      @headers = headers
    end

    def message
      tmp = super()
      @name + ((tmp and !tmp.empty?) ? " -- #{tmp}" : '')
    end
  end
  class InvalidError < HTTPError
    def initialize(msg=nil,headers=nil)
      super(405,'Method Not Allowed',msg,headers)
    end
  end
  class NotFoundError < HTTPError
    def initialize(msg=nil,headers=nil)
      super(404,'File Not Found',msg,headers)
    end
  end
  class UnauthorizedError < HTTPError
    def initialize(msg=nil,headers=nil)
      super(401,'Unauthorized',msg,headers)
    end
  end
  class ForbiddenError < HTTPError
    def initialize(msg=nil,headers=nil)
      super(403,'Forbidden',msg,headers)
    end
  end
  class UnsupportedError < HTTPError
    def initialize(msg=nil,headers=nil)
      super(415,'Unsupported Media Type',msg,headers)
    end
  end
  class UnavailableError < HTTPError
    def initialize(msg=nil,headers=nil)
      super(503,'Service Unavailable',msg,headers)
    end
  end

  class ServletTimeout < Exception
    def set_backtrace(array)
      time=Time.now()
      $stderr.puts("[#{time}] Servlet execution is timed out")
      $stderr.puts("[#{time}] #{array.join("\n[#{time}] ")}")
      $stderr.puts("[#{time}] === End of trace ===")
      $stderr.flush()
      super(array)
    end
  end


  class ContentBinding < Hash
  end

  class RequestHandler
    TYPES = {
      :json => 'application/json',
      :yaml => 'application/x-yaml',
    }
    attr_accessor :accept, :encoding
    def initialize(request)
      @request = request
      if @request['Content-Length']
        @body = @request.body
      else
        @body = ''
      end
      @uri = @request.request_uri
      @accept = self.class.parse_header_list(@request['Accept'])
      @encoding = self.class.parse_header_list(@request['Accept-Encoding'])

      if @accept and (@accept & TYPES.values).empty?
        raise HTTPError.new(406,'Not Acceptable',@accept.join(', '))
      end
    end

    def free()
      @request = nil
      @body = nil
      @uri = nil
      @accept = nil
      @encoding = nil
    end

    def self.parse_header_list(val)
      if val and !val.strip.empty?
        ret = val.split(',').collect{|v| v.split(';').first.strip.downcase}
        if (ret & ['*','*/*']).empty?
          ret
        else
          nil
        end
      else
        nil
      end
    end

    def params()
      res = {}
      # Parse HTTP request's body
      if !@body.nil? and !@body.empty?
        if @request['Content-Type'] and !@request['Content-Type'].strip.empty?
          if @request['Content-Length'] and !@request['Content-Length'].strip.empty?
            length = nil
            begin
              length = @request['Content-Length'].to_i
            rescue
              raise HTTPError.new(411,'Length Required',
                "The Content-Length HTTP header has to be an integer")
            end

            if length > MAX_CONTENT_SIZE
              raise HTTPError.new(413,'Request Entity Too Large',
                "The content in the request's body cannot be greater than "\
                "#{MAX_CONTENT_SIZE} bytes")
            end
          else
            raise HTTPError.new(411,'Length Required',
              "The Content-Length HTTP header has to be sed")
          end

          case @request['Content-Type'].split(';').first.downcase
          when TYPES[:json]
            begin
              res = JSON::load(@body)
            rescue JSON::ParserError
              raise UnsupportedError.new("Invalid JSON content in request's body")
            end
          when TYPES[:yaml]
            begin
              res = YAML::load(@body)
            rescue SyntaxError
              raise UnsupportedError.new("Invalid YAML content in request's body")

            end
          else
            raise UnsupportedError.new(
              "The Content-Type #{@request['Content-Type']} is not supported"\
              "\nSupported: #{TYPES.values.join(', ')}")
          end
        else
          raise UnsupportedError.new('The Content-Type HTTP header has to be set')
        end
      end

      unless res.is_a?(Hash)
        raise UnsupportedError.new(
          'The content of the request\'s body must be ''a Hash')
      end

      # Parse HTTP request's query string
      if @uri.query and @uri.query.size > MAX_CONTENT_SIZE
        raise HTTPError.new(414,'Request-URI Too Long',
          "The the request's query size cannot be greater than "\
          "#{MAX_CONTENT_SIZE} chars")
      end

      # CGI.parse do decode_www_form
      CGI.parse(@uri.query||'').each do |key,val|
        if val.is_a?(Array)
          if val.size > 1
            res[key] = val
          else
            res[key] = val[0]
          end
        elsif val.is_a?(String)
            res[key] = val
        else
          raise
        end
      end

      res
    end

    def output(obj)
      type = nil
      content = nil
      if @accept
        case (@accept & TYPES.values)[0]
        when TYPES[:json]
          type,content = [ TYPES[:json], JSON.pretty_generate(obj) ]
        when TYPES[:yaml]
          type,content = [ TYPES[:yaml], obj.to_yaml ]
        else
          raise HTTPError.new(406,'Not Acceptable',@accept.join(', '))
        end
      else
        type,content = [ TYPES[:json], JSON.pretty_generate(obj) ]
      end

      type = type.dup
      type << "; charset=\"#{content.encoding.to_s.strip}\""

      if @encoding and @encoding.include?('gzip')
        sio = StringIO.new('w')
        gzw = Zlib::GzipWriter.new(sio)
        gzw.write(content)
        gzw.close
        content = sio.string
        #sio.close
        [type, 'gzip', content]
      else
        [type, nil, content]
      end
    end
  end

  class HTTPdHandler < WEBrick::HTTPServlet::AbstractServlet
    def initialize(allowed_methods)
      if allowed_methods.is_a?(Array)
        @allowed = allowed_methods.collect{|m| m.to_s.upcase.to_sym}
      elsif allowed_methods.is_a?(Symbol)
        @allowed = [allowed_methods.to_s.upcase.to_sym]
      else
        raise
      end
      # class_eval "alias :\"do_#{m.to_s.upcase}\", :do_METHOD"
    end

    #This function override the inspect function of Object class and it avoids a recursive inspection by webrick
    def inspect()
      self.class.name
    end

    def get_instance(server, *options)
      self
    end

    def get_method(request)
      request.request_method.upcase.to_sym
    end

    def kill()
      Thread.current[:run_thr].kill if Thread.current[:run_thr]
    end

    def treatment(req,resp)
#
# = A client disconnection kills the handle thread. 
#   The handle thread can allocate some resources (ex : refs token in cache or compressedCSV) and be killed
#   out of all ensure and it does not return ret.
#
#      TODO : implement a method to kill kastat when a user interrupts the client.
#
#      ret = nil
#      Thread.current[:run_thr] = Thread.new{ ret = handle(req,resp,request_handler) }
#
#      sock = Thread.current[:WEBrickSocket]
#      while Thread.current[:run_thr] and Thread.current[:run_thr].alive? do
#        if IO.select([sock], nil, nil, 0.5) and sock.eof?
#        # The client disconnected
#          kill()
#          request_handler.free
#          request_handler = nil
#          raise WEBrick::HTTPStatus::EOFError
#        end
#      end
#      Thread.current[:run_thr].join if Thread.current[:run_thr]
#      Thread.current[:run_thr] = nil
#
#      if IO.select([sock], nil, nil, 0) and sock.eof?
#      # The client disconnected
#        request_handler.free
#        request_handler = nil
#        ret.free if ret.respond_to?(:free)
#        ret = nil
#        raise WEBrick::HTTPStatus::EOFError
#      end
# ======

      # The webrick server has pool of threads. Threrefore, when a servlet never
      # finishes, the used thread becomes busy.  When all threads are busy, the webrick
      # server can't respond to new request.  This timeout raise an exception after 10
      # min if the servlet has not finished. This exception shows where the thread was
      # locked.

      Timeout.timeout(SERVLET_TIMEOUT, ServletTimeout) do
        request_handler = RequestHandler.new(req)
        ret = handle(req,resp,request_handler)
        return [ret,request_handler]
      end
    end

    def do_METHOD(request, response)
      ret = nil
      if @allowed.include?(get_method(request))
        begin
          ret,request_handler = treatment(request,response)
          res = ret

          # No caching
          response['ETag'] = nil
          response['Cache-Control'] = 'no-store, no-cache'
          response['Pragma'] = 'no-cache'

          response.status = 200
          if ret.is_a?(String)
            response['Content-Type'] = 'text/plain'
          elsif ret.nil?
            res = ''
            response['Content-Type'] = 'text/plain'
          elsif ret.is_a?(TrueClass)
            res = 'true'
            response['Content-Type'] = 'text/plain'
          elsif ret.is_a?(File)
            # Ugly hack since Webrick filehandler automatically closes files
            ret.close unless ret.closed?
            ret = res = open(ret.path,'rb')

            st = ret.stat
            response['ETag'] = sprintf("\"%x-%x-%x\"",st.ino,st.size,
              st.mtime.to_i)
            response['Last-Modified'] = st.mtime.httpdate
            response['Content-Type'] = 'application/octet-stream'
          elsif ret.is_a?(CompressedCSV)
            # Do not respond if client do not accept gzip
            ret.close unless ret.closed?
            if !request_handler.encoding or request_handler.encoding.include?('gzip')
              response['Content-Type'] = 'text/csv'
              response['Content-Encoding'] = ret.algorithm
              res = ret.file
            else
              ret.free
              raise HTTPError.new(406,'Not Acceptable','Content-Encoding: gzip')
            end
          else
            response['Content-Type'],response['Content-Encoding'],res = \
              request_handler.output(ret)
          end
          request_handler.free
          request_handler = nil
          ret = nil
        rescue HTTPError => e
          res = e.message
          response.status = e.code
          e.headers.each_pair{|k,v| response[k] = v} if e.headers
          response['Content-Type'] = 'text/plain'
          if e.is_a?(InvalidError)
            response['Allow'] = @allowed.collect{|m|m.to_s}.join(',')
          end
        rescue KadeployError => ke
          res = KadeployError.to_msg(ke.errno)
          res += " -- #{ke.message}" if ke.message and !ke.message.empty?
          response.status = 400
          response['Content-Type'] = 'text/plain'
          response['X-Application-Error-Code'] = ke.errno
          response['X-Application-Error-Info'] = Base64.strict_encode64(res)
          $stderr.puts("[#{Time.now}] Internal Server Error  #{res}")
          $stderr.puts(ke.backtrace())
          $stderr.flush
        rescue Exception => e
          res = "---- #{e.class.name} ----\n"\
            "#{e.message}\n"\
            "---- Stack trace ----\n"\
            "#{e.backtrace.join("\n")}\n"\
            "---------------------"
          #Write the error in stderr
          $stderr.puts("[#{Time.now}] Internal Server Error  #{res}")
          $stderr.flush
          response.status = 500
          response['Content-Type'] = 'text/plain'
        end
      else
        res = 'Method Not Allowed'
        response.status = 405
        response['Content-Type'] = 'text/plain'
        response['Allow'] = (@allowed + [:HEAD]).collect{|m|m.to_s}.join(',')
      end
      if response['Content-Type'] == 'text/plain'
        res += "\n"
        response['Content-Type'] << "; charset=\"#{res.encoding.to_s.strip}\""
      end
      if res.is_a?(String)
        response['Content-Length'] = res.bytesize
      else
        response['Content-Length'] = res.size
      end
      response.body = res unless get_method(request) == :HEAD
      res = nil
    end

    def handle(request, response, request_handler)
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

    def handle(request, response, request_handler)
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

    def handle(request, response, request_handler, args=nil, params={})
      args = @args.dup if args.nil? and !@args.nil?
      args = args[get_method(request)] if args.is_a?(ContentBinding)
      args = [] if args.nil?
      args = [args] unless args.is_a?(Array)

      name = nil
      if @method.is_a?(ContentBinding)
        name = @method[get_method(request)].to_s.to_sym
      else
        name = @method.to_s.to_sym
      end

      params[:kind] = get_method(request)
      params[:request] = request
      params[:params] = request_handler.params

      begin
        return @obj.send(name,params,*args)#,&proc{request})
      rescue ArgumentError => e
      # if the problem is that the method is called with the wrong nb of args
        if e.backtrace[0].split(/\s+/)[-1] =~ /#{name}/ \
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
    def initialize(allowed_methods,obj,method,filter,names=nil,static=nil)
      super(allowed_methods,obj,method,nil)
      @obj = obj
      @filter = filter
      @names = names
      @static = static
    end

    def handle(request, response, request_handler)
      args = (@args.nil? ? nil : @args.dup)
      args = [] if args.nil?
      params = {}

      filter = nil
      if @filter.is_a?(ContentBinding)
        filter = @filter[get_method(request)]
      #elsif @filter.is_a?(Hash)
      #  filter = @filter[:dynamic] || []
      #  @args += @filter[:static] if @filter[:static]
      else
        filter = @filter
      end

      if @static
        if @static.is_a?(ContentBinding)
          args += @static[get_method(request)]
        else
          args += @static
        end
      end

      names = nil
      if @names.is_a?(ContentBinding)
        names = @names[get_method(request)]
      else
        names = @names
      end
      names = [] unless names

      #prefix = nil
      #if @method_prefix.is_a?(ContentBinding)
      #  prefix = @method_prefix[get_method(request)]
      #else
      #  prefix = @method_prefix
      #end

      fields = request.request_uri.path.split('/')[1..-1]
      args += fields.values_at(*filter).compact.collect{|v| URI.decode_www_form_component(v)}
      params[:names] = fields.values_at(*names).compact
      params[:names] = nil if params[:names].empty?
      #if suffix.empty?
      #  @method = prefix.to_sym
      #else
      #  @method = (prefix.to_s + '_' + suffix.join('_')).to_sym
      #end

      return super(request, response, request_handler, args, params)
    end
  end

  class ContentHandler < HTTPdHandler
    def initialize(allowed_methods,content)
      super(allowed_methods)
      @content = content
    end

    def handle(request, response, request_handler)
      if @content.is_a?(ContentBinding)
        return @content[get_method(request)]
      else
        return @content
      end
    end
  end

  def self.get_sockaddr(request)
    request.instance_variable_get(:@peeraddr)
  end

  class Server
    attr_reader :host, :port, :logs
    def initialize(host='',port=0,secure=true,local=false,cert=nil,private_key=nil,dh_seeds={},httpd_logfile=nil)
      raise if cert and !private_key
      @host = host || ''
      @port = port || 0
      @secure = secure
      @local = local
      @cert = cert
      @private_key = private_key
      # A list of DH seeds instances for SSL per-session key exchange purpose
      @dh_seeds = dh_seeds

      @logs = {}
      if httpd_logfile
        if !File.writable?(File.join(httpd_logfile,LOGFILE_HTTPD)) \
          and !File.writable?(File.dirname(httpd_logfile))
          self.class.error("Log directory '#{httpd_logfile}' not writable")
        end
        @logs[:httpd] = File.open(File.join(httpd_logfile),'a+')
      elsif $kadeploy_logdir
        unless File.directory?($kadeploy_logdir)
          self.class.error("Log directory '#{$kadeploy_logdir}' does not exists")
        end
        if !File.writable?(File.join($kadeploy_logdir,LOGFILE_HTTPD)) \
          and !File.writable?($kadeploy_logdir)
          self.class.error("Log directory '#{$kadeploy_logdir}' not writable")
        end
        @logs[:httpd] = File.open(File.join($kadeploy_logdir,LOGFILE_HTTPD),'a+')
      end

      if $kadeploy_logdir
        unless File.directory?($kadeploy_logdir)
          self.class.error("Log directory '#{$kadeploy_logdir}' does not exists")
        end
        if !File.writable?(File.join($kadeploy_logdir,LOGFILE_ACCESS)) \
          and !File.writable?($kadeploy_logdir)
          self.class.error("Log directory '#{$kadeploy_logdir}' not writable")
        end
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

      if @local
        @host = 'localhost'
        opts[:BindAddress] = 'localhost'
      else
        opts[:BindAddress] = '0.0.0.0'
      end

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

      if @secure
        opts[:SSLEnable] = true
        # Generate DH seeds to avoid man-in-the-middle attacks since ruby
        # is using static-defined numbers if no DH is providden
        if @dh_seeds
          @dh_seeds[1024] = OpenSSL::PKey::DH.new(1024) unless @dh_seeds[1024]

          # Do not threat ciphers instructions (export)
          opts[:SSLTmpDhCallback] = proc{|_,_,len| @dh_seeds[len] || (@dh_seeds[len] = OpenSSL::PKey::DH.new(len))}
        end

        if @cert
          opts[:SSLCertificate] = @cert
          opts[:SSLPrivateKey] = @private_key
        else
          opts[:SSLCertName] = [['CN',@host]]
        end

        # TODO: load a CA certificate to identify clients
        opts[:SSLVerifyClient] = OpenSSL::SSL::VERIFY_NONE
      end

      @server = WEBrick::HTTPServer.new(opts)
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
      methods = [methods] if methods.is_a?(Symbol)
      case kind
      when :method
        raise unless params.is_a?(Hash) and params[:object] and params[:method]
        @server.mount(path,MethodHandler.new(methods,params[:object],params[:method],params[:args]))
      when :filter
        raise unless params.is_a?(Hash) and params[:object] and params[:method] and params[:args]
        @server.mount(path,MethodFilterHandler.new(methods,params[:object],params[:method],params[:args],params[:name],params[:static]))
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
      @server.umount(path)
    end
  end
end

end
