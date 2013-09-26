require 'error'
require 'httpd'
require 'nodes'

require 'openssl'
require 'uri'
require 'time'

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

  def check(value, klass, opts={}, &block)
    opts[:value] = value
    parse(nil,klass,opts,&block)
  end

  def parse(name, klass, opts={})
    @curparam = name
    param = opts[:value] || @params[name]
    errno = opts[:errno] || APIError::INVALID_OPTION

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

    if opts[:values]
      if param.is_a?(Array)
        # Check if Array1 includes Array2
        error(errno,"must have a value in (#{opts[:values].join(',')})") unless (param-opts[:values]).empty?
      else
        error(errno,"must have a value in (#{opts[:values].join(',')})") unless opts[:values].include?(param)
      end
    end

    if opts[:regexp] and !param =~ opts[:regexp]
      error(errno,"must be like #{opts[:regexp]}")
    end

    if opts[:range] and !opts[:range].include?(param)
      error(errno,"must be in the range #{opts[:range].to_s}")
    end

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
          error(APIError::INVALID_NODELIST,"The node #{host} does not exist")
        end
      end
    when :vlan
      if @config.common.vlan_hostname_suffix.empty? or @config.common.set_vlan_cmd.empty?
        error(APIError::INVALID_VLAN, "The VLAN management is disabled")
      end
    when :custom_ops
      ret = { :operations => {}, :overrides => {}}
      customops = ret[:operations]
      customover = ret[:overrides]

      param.each_pair do |macro,micros|
        error(errno,'Macrostep name must be a String') unless macro.is_a?(String)
        error(errno,'Macrostep description must be a Hash') unless micros.is_a?(Hash)
        error(errno,"Invalid macrostep '#{macro}'") \
          if !Configuration::check_macrostep_interface(macro) and \
          !Configuration::check_macrostep_instance(macro)

        customops[macro.to_sym] = {} unless customops[macro.to_sym]

        micros.each_pair do |micro,operations|
          error(errno,'Microstep name must be a String') unless micro.is_a?(String)
          error(errno,"The microstep '#{micro}' is empty") unless operations
          error(errno,'Microstep description must be a Hash') unless operations.is_a?(Hash)
          error(errno,"Invalid microstep '#{micro}'") \
            unless Configuration::check_microstep(micro)
          cp = Configuration::Parser.new(operations)
          begin
            tmp = Configuration::parse_custom_operations(cp,micro,
              :set_target=>true)
          rescue ArgumentError => ae
            error(errno,"#{macro}/#{micro}, #{ae.message}")
          end

          if tmp[:over]
            customover[macro.to_sym] = {} unless customover[macro.to_sym]
            customover[macro.to_sym][micro.to_sym] = true
            tmp.delete[:over]
          end

          customops[macro.to_sym][micro.to_sym] = []
          tmp.values.each{|v| customops[macro.to_sym][micro.to_sym] += v if v}
        end
      end
      param = ret
    when :custom_automata
      cp = Configuration::Parser.new(param)
      begin
        param = Configuration::parse_custom_macrosteps(cp)
      rescue ArgumentError => ae
        error(errno,ae.message)
      end
    when :date
      begin
        param = Time.parse(param)
      rescue
        error("Invalid date '#{param}', please use RFC 2616 notation")
      end
    end

    yield(param) if block_given? and param

    @curparam = nil

    param
  end

end

end
