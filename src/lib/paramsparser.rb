require 'error'
require 'httpd'
require 'nodes'

require 'openssl'
require 'uri'

module Kadeploy

class ParamsParser
  def initialize(params,config)
    raise unless params.is_a?(Hash)
    @params = params
    @config = config
    @curparam = nil
  end

  def error(errno,msg='',klass=nil)
    msg = "Parameter '#{@curparam}': #{msg}" if @curparam
    if klass
      raise klass.new(msg)
    else
      raise KadeployError.new(errno,nil,msg)
    end
  end

  def check(value, klass, opts={})
    opts[:value] = value
    parse(nil,klass,opts)
  end

  def parse(name, klass, opts={})
    @curparam = name
    param = opts[:value] || @params[name]
    errno = opts[:errno] || APIError::INVALID_CONTENT

    if opts[:toggle]
      if @params.keys.include?(name) and !param.is_a?(FalseClass)
        return true
      else
        return false
      end
    end

    if param.nil?
      if opts[:default]
        return opts[:default]
      elsif opts[:mandatory]
        msg = "mandatory"
        case opts[:mandatory]
        when :invalid
          error(nil,msg,HTTPd::InvalidError)
        when :forbidden
          error(nil,msg,HTTPd::ForbiddenError)
        when :unauthorized
          error(nil,msg,HTTPd::UnauthorizedError)
        else
          error(errno,"mandatory")
        end
      else
        return nil
      end
    end

    param = [param] if klass.is_a?(Class) and klass == Array and param.is_a?(String) and !opts[:strict]

    if klass.is_a?(Array)
      error(errno,"should be #{klass.join(' or ')}") \
        unless klass.include?(param.class)
    else
      error(errno,"should be a #{klass.name}") \
        if !klass.nil? and !param.is_a?(klass)
    end

    error(errno,"cannot be empty") \
      if param.respond_to?(:empty?) and param.empty? and !opts[:emptiable]

    error(errno,"must have a value in (#{opts[:values].join(',')})") if opts[:values] and !opts[:values].include?(param)

    case opts[:type]
    when :x509
      param = param.join("\n") if param.is_a?(Array)
      begin
        param = OpenSSL::X509::Certificate.new(param)
      rescue Exception => e
        error(errno,"invalid x509 certificate (#{e.message})")
      end
    when :uri
      begin
        param = URI.parse(param)
      rescue Exception => e
        error(errno,"invalid URI (#{e.message})")
      end

      error(APIError::INVALID_CLIENT,'Invalid client protocol') \
        unless ['http','https'].include?(param.scheme.downcase)

      error(APIError::INVALID_CLIENT, 'Secure connection is mandatory for the client fileserver') \
        if @config.common.secure_client and param.scheme.downcase == 'http'
    when :nodeset
      # Get hostlist
      hosts = []
      param.each do |host|
        if Nodes::REGEXP_NODELIST =~ host
          hosts += Nodes::NodeSet::nodes_list_expand(host)
        else
          hosts << host.strip
        end
      end

      # Create a nodeset
      param = Nodes::NodeSet.new(0)
      hosts.each do |host|
        if node = @config.common.nodes_desc.get_node_by_host(host)
          param.push(node.dup)
        else
          error(KadeployError::NODE_NOT_EXIST,host)
        end
      end
    when :vlan
      if @config.common.vlan_hostname_suffix.empty? or @config.common.set_vlan_cmd.empty?
        error(KadeployError::VLAN_MGMT_DISABLED)
      end
    end

    yield(param) if block_given? and param

    @curparam = nil

    param
  end
end

end
