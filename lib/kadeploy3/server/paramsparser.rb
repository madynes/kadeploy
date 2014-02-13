require 'uri'
require 'time'

module Kadeploy

class ParamsParser
  def initialize(params,config)
    raise unless params.is_a?(Hash)
    @params = params
    @secure_client = config.common.secure_client
    @nodes = Nodes::NodeSet.new(0)
    config.common.nodes.duplicate(@nodes)
    @vlan_hostname_suffix = config.common.vlan_hostname_suffix.dup
    @set_vlan_cmd = config.common.set_vlan_cmd
    @curparam = nil
  end

  def free()
    @params = nil
    @secure_client = nil
    @nodes = nil
    @vlan_hostname_suffix = nil
    @set_vlan_cmd = nil
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
    when :uri
      begin
        param = URI.parse(param)
      rescue Exception => e
        error(errno,"invalid URI (#{e.message})")
      end

      error(APIError::INVALID_CLIENT,'Invalid client protocol') \
        unless ['http','https'].include?(param.scheme.downcase)

      error(APIError::INVALID_CLIENT, 'Secure connection is mandatory for the client fileserver') \
        if @secure_client and param.scheme.downcase == 'http'
    when :node
      error(APIError::INVALID_NODELIST,"Must be a single node") if Nodes::REGEXP_NODELIST =~ param

      # Get the node
      param = param.strip
      error(APIError::INVALID_NODELIST,"Empty node name") if param.empty?
      unless param = @nodes.get_node(param)
        error(APIError::INVALID_NODELIST,"The node #{param} does not exist")
      end
    when :nodeset
      # Get hostlist
      hosts = []
      param.each do |host|
        if Nodes::REGEXP_NODELIST =~ host.strip
          hosts += Nodes::NodeSet::nodes_list_expand(host.strip)
        else
          hosts << host.strip
        end
      end

      # Create a nodeset
      param = Nodes::NodeSet.new(0)
      hosts.each do |host|
        host = host.strip
        error(APIError::INVALID_NODELIST,"Empty node name") if host.empty?
        node = @nodes.get_node(host)
        if node
          if node.is_a?(Array)
            error(APIError::INVALID_NODELIST,"Ambibuous node name '#{host}' that can refer to #{node.collect{|n| n.hostname}.join(' or ')}")
          else
            param.push(node)
          end
        else
          error(APIError::INVALID_NODELIST,"The node '#{host}' does not exist")
        end
      end
      Nodes::sort_list(param.set)
    when :vlan
      if @vlan_hostname_suffix.empty? or @set_vlan_cmd.empty?
        error(APIError::INVALID_VLAN, "The VLAN management is disabled")
      end
    when :breakpoint
      ret = []
      raise unless opts[:kind]
      if param =~ /^(\w+)(?::(\w+))?$/
        if Configuration::check_macrostep_instance(Regexp.last_match(1),opts[:kind]) or Configuration::check_macrostep_interface(Regexp.last_match(1),opts[:kind])
          ret[0] = Regexp.last_match(1)
        else
          error(errno,"Invalid macrostep name '#{Regexp.last_match(1)}'")
        end
        if Regexp.last_match(2) and !Regexp.last_match(2).empty?
          if Configuration::check_microstep(Regexp.last_match(2))
            ret[1] = Regexp.last_match(2)
          else
            error(errno,"Invalid microstep name '#{Regexp.last_match(2)}'")
          end
        end
        param = ret
      else
        error(errno,'The breakpoint should be specified as macrostep_name:microstep_name or macrostep_name')
      end
    when :custom_ops
      ret = { :operations => {}, :overrides => {}}
      raise unless opts[:kind]
      customops = ret[:operations]
      customover = ret[:overrides]

      param.each_pair do |macro,micros|
        error(errno,'Macrostep name must be a String') unless macro.is_a?(String)
        error(errno,'Macrostep description must be a Hash') unless micros.is_a?(Hash)
        error(errno,"Invalid macrostep '#{macro}'") \
          if !Configuration::check_macrostep_interface(macro,opts[:kind]) and \
          !Configuration::check_macrostep_instance(macro,opts[:kind])

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
