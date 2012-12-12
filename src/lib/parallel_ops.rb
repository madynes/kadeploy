# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Contrib libs
require 'taktuk'

#Ruby libs
require 'yaml'
require 'socket'
require 'ping'

#module ParallelOperations
  #class ParallelOps
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
      @taktuk.kill unless @taktuk.nil?
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
      do_taktuk do |tak|
        tak.broadcast_exec[command]
        tak.seq!.broadcast_input_file[opts[:input_file]] if opts[:input_file]
        res = tak.run!
        takbin = tak.binary
        takargs = tak.args
      end

      ret = nil
      if res
        nodes_updates(res)
        ret = nodes_sort(expects)
      else
        ret = [[],@nodes.set.dup]
      end
      @output.debug("#{takbin} #{takargs.join(' ')}", @nodes)
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
      do_taktuk do |tak|
        res = tak.broadcast_put[src][dst].run!
        takbin = tak.binary
        takargs = tak.args
      end

      ret = nil
      if res
        nodes_updates(res)
        ret = nodes_sort(expects)
      else
        ret = [[],@nodes.set.dup]
      end
      @output.debug("#{takbin} #{takargs.join(' ')}", @nodes)
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
      @context[:config].set_node_state(node.hostname,'','',opts[:node_state]) unless opts[:node_state].nil?
    end

    # Set information about a Taktuk command execution
    def nodes_update(result, fieldkey = :host, fieldval = :line)
      res = result.compact!([fieldval]).group_by { |v| v[fieldkey] }
      res.each_pair do |host,values|
        node = node_get(host)
        ret = []
        values.each do |value|
          if value[fieldval].is_a?(Array)
            ret += value[fieldval]
          else
            ret << value[fieldval]
          end
        end
        yield(node,ret)
      end
    end

    # Set information about a Taktuk command execution
    def nodes_updates(results)
      nodes_update(results[:output]) do |node,val|
        node.last_cmd_stdout = val.join("\n") if node
      end
      nodes_update(results[:error]) do |node,val|
        node.last_cmd_stderr = "#{val.join("\n")}\n" if node
      end
      nodes_update(results[:status]) do |node,val|
        node.last_cmd_exit_status = val[0] if node
      end
      nodes_update(results[:connector]) do |node,val|
        next unless node
        val.each do |v|
          if !(v =~ /^Warning:.*$/)
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
      unless opts[:scattering].nil?
        case opts[:scattering]
        when :chain
          taktuk_opts[:dynamic] = 1
        when :tree
          taktuk_opts[:dynamic] = tree_arity if (tree_arity > 0)
        else
          raise "Invalid structure for broadcasting file"
        end
      end

      taktuk(nodes_array(),taktuk_opts)
    end

    def do_taktuk(opts={})
      @taktuk = taktuk_init(opts)
      yield(@taktuk)
      @taktuk = nil
    end
  end
#end
