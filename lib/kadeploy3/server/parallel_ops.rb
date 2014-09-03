require 'yaml'
require 'socket'

module Kadeploy
  class ParallelOperation
    @nodes = nil
    @output = nil
    @context = nil
    @taktuk = nil

    # Constructor of ParallelOps
    #
    # Arguments
    # * nodes: instance of NodeSet
    # * config: instance of Config
    # * cluster_config: cluster specific config
    # * output: OutputControl instance
    # * process_container: process container
    # Output
    # * nothing
    def initialize(nodes, context, output)
      @nodes = nodes
      @context = context
      @output = output
      @taktuk = nil
    end

    def kill
      @taktuk.kill! unless @taktuk.nil?
      #free() It is a race condition and it will be freed by do_taktuk
    end

    def free
      @nodes = nil
      @output = nil
      @context = nil
      @taktuk.free! if @taktuk
      @taktuk = nil
    end

    # Exec a command with TakTuk
    #
    # Arguments
    # * command: command to execute
    # * opts: Hash of options: :input_file, :scattering, ....
    # * expects: Hash of expectations, will be used to sort nodes in OK and KO sets: :stdout, :stderr, :status, ...
    # Output
    # * returns an array that contains two arrays ([0] is the nodes OK and [1] is the nodes KO)
    def taktuk_exec(command,opts={},expects={})
      nodes_init(:stdout => '', :stderr => '', :status => '0')

      res = nil
      takbin = nil
      takargs = nil
      stderr = nil
      do_taktuk do |tak|
        tak.broadcast_exec[command]
        tak.seq!.broadcast_input_file[opts[:input_file]] if opts[:input_file]
        res = tak.run!(:outputs_size => @context[:common].taktuk_outputs_size)
        takbin = tak.binary
        takargs = tak.args
        stderr = tak.stderr
      end

      ret = nil
      if res
        nodes_updates(res)
        ret = nodes_sort(expects)
        res.each_value{|v| v.free if v}
        res.clear
      else
        if stderr and !stderr.empty?
          @nodes.set.each do |node|
            node.last_cmd_stderr = stderr
          end
        end
        ret = [[],@nodes.set.dup]
      end
      res = nil
      @output.push("#{takbin} #{takargs.join(' ')}", @nodes) if @output
      ret
    end

    # Send a file with TakTuk
    #
    # Arguments
    # * src: file to send
    # * dest: destination dir
    # * opts: Hash of options: :input_file, :scattering, ....
    # * expects: Hash of expectations, will be used to sort nodes in OK and KO sets: :stdout, :stderr, :status, ...
    # Output
    # * returns an array that contains two arrays ([0] is the nodes OK and [1] is the nodes KO)
    def taktuk_sendfile(src,dst,opts={},expects={})
      nodes_init(:stdout => '', :stderr => '', :status => '0')

      res = nil
      takbin = nil
      takargs = nil
      stderr = nil
      do_taktuk do |tak|
        res = tak.broadcast_put[src][dst].run!(:outputs_size => @context[:common].taktuk_outputs_size)
        takbin = tak.binary
        takargs = tak.args
        stderr = tak.stderr
      end

      ret = nil
      if res
        nodes_updates(res)
        ret = nodes_sort(expects)
        res.each_value{|v| v.free if v}
        res.clear
      else
        if stderr and !stderr.empty?
          @nodes.set.each do |node|
            node.last_cmd_stderr = stderr
          end
        end
        ret = [[],@nodes.set.dup]
      end
      res = nil
      @output.push("#{takbin} #{takargs.join(' ')}", @nodes) if @output
      ret
    end


    private

    def nodes_init(opts={})
      @nodes.set.each do |node|
        node_set(node,opts)
      end
    end

    def nodes_array()
      ret = @nodes.make_sorted_array_of_nodes
      if @context[:cluster].use_ip_to_deploy then
        ret.collect!{ |node| node.ip }
      else
        ret.collect!{ |node| node.hostname }
      end
      ret
    end

    # Get a node object by it's host
    def node_get(host)
      ret = nil
      if @context[:cluster].use_ip_to_deploy then
        ret = @nodes.get_node_by_ip(host)
      else
        ret = @nodes.get_node_by_host(host)
      end
      ret
    end

    def node_set(node,opts={})
      node.last_cmd_stdout = opts[:stdout] unless opts[:stdout].nil?
      node.last_cmd_stderr = opts[:stderr] unless opts[:stderr].nil?
      node.last_cmd_exit_status = opts[:status] unless opts[:status].nil?
      node.state = opts[:state] unless opts[:state].nil?
      @context[:states].set(node.hostname,'','',opts[:node_state]) unless opts[:node_state].nil?
    end

    # Set information about a Taktuk command execution
    def nodes_update(result, fieldkey = nil, fieldval = :line)
      if fieldkey
        result.each_pair do |host,pids|
          pids.each_value do |value|
            value[fieldkey].each_index do |i|
              node = node_get(value[fieldkey][i])
              if value[fieldval].is_a?(Array)
                yield(node,[value[fieldval][i]])
              else
                yield(node,[value[fieldval]])
              end
            end
          end
        end
      else
        result.each_pair do |host,pids|
          node = node_get(host)
          ret = nil
          pids.each_value do |value|
            if value[fieldval].is_a?(Array)
              ret = [] unless ret
              ret += value[fieldval]
            elsif value[fieldval].is_a?(String)
              if ret
                ret << value[fieldval]
              else
                ret = value[fieldval]
              end
            else
              raise
            end
          end
          yield(node,ret)
        end
      end
    end

    # Set information about a Taktuk command execution
    def nodes_updates(results)
      nodes_update(results[:output]) do |node,val|
        node.last_cmd_stdout = val if node
      end

      nodes_update(results[:error]) do |node,val|
        node.last_cmd_stderr = "#{val.join("\n")}\n" if node
      end

      nodes_update(results[:status]) do |node,val|
        node.last_cmd_exit_status = val[0] if node
      end

      regexp = /^Warning:.*$/
      nodes_update(results[:connector]) do |node,val|
        next unless node
        val.each do |v|
          if !(v =~ regexp)
            node.last_cmd_exit_status = "256"
            node.last_cmd_stderr = '' unless node.last_cmd_stderr
            node.last_cmd_stderr += "TAKTUK-ERROR-connector: #{v}\n"
          end
        end
      end

      nodes_update(results[:state],:peer) do |node,val|
        next unless node
        val.each do |v|
          if TakTuk::StateStream.check?(:error,v)
            node.last_cmd_exit_status = v
            node.last_cmd_stderr = '' unless node.last_cmd_stderr
            node.last_cmd_stderr += "TAKTUK-ERROR-state: #{TakTuk::StateStream::errmsg(v.to_i)}\n"
          end
        end
      end
    end

    def nodes_sort(expects={})
      good = []
      bad = []

      @nodes.set.each do |node|
        status = (expects[:status] ? expects[:status] : ['0'])

        unless status.include?(node.last_cmd_exit_status)
          bad << node
          next
        end

        if expects[:output] and node.last_cmd_stdout.split("\n")[0] != expects[:output]
          bad << node
          next
        end

        if expects[:state] and node.state != expects[:state]
          bad << node
          next
        end
        good << node
      end
      [good,bad]
    end

    def taktuk_init(opts={})
      taktuk_opts = {}

      connector = @context[:common].taktuk_connector
      taktuk_opts[:connector] = connector unless connector.empty?

      taktuk_opts[:self_propagate] = nil if @context[:common].taktuk_auto_propagate

      tree_arity = @context[:common].taktuk_tree_arity
      if opts[:scattering].nil?
        taktuk_opts[:dynamic] = tree_arity
      else
        case opts[:scattering]
        when :chain
          taktuk_opts[:dynamic] = 1
        when :tree
          taktuk_opts[:dynamic] = tree_arity if (tree_arity > 0)
        else
          raise "Invalid structure for broadcasting file"
        end
      end

      TakTuk.taktuk(nodes_array(),taktuk_opts)
    end

    def do_taktuk(opts={})
      @taktuk = taktuk_init(opts)
      yield(@taktuk)
      @taktuk.free! if @taktuk
      @taktuk = nil
    end
  end
end
