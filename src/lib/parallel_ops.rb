# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Contrib libs
require 'taktuk_wrapper'

#Ruby libs
require 'yaml'
require 'socket'
require 'ping'

module ParallelOperations
  class ParallelOps
    @nodes = nil
    @output = nil
    @config = nil
    @cluster_config = nil
    @taktuk = nil
    @waitreboot_threads = nil

    @instance_thread = nil
    @process_container = nil

    # Constructor of ParallelOps
    #
    # Arguments
    # * nodes: instance of NodeSet
    # * config: instance of Config
    # * cluster_config: cluster specific config
    # * output: OutputControl instance
    # * instance_thread: current thread instance
    # * process_container: process container
    # Output
    # * nothing
    def initialize(nodes, config, cluster_config, output, instance_thread, process_container)
      @nodes = nodes
      @config = config
      @cluster_config = cluster_config
      @output = output
      @taktuk = nil

      @instance_thread = instance_thread
      @process_container = process_container
    end

    def kill
      @taktuk.kill unless @taktuk.nil?
      unless @waitreboot_threads.nil?
        @waitreboot_threads.list.each do |thr|
          Thread.kill(thr)
        end
      end
    end

    def node_set(node,opts={})
      node.last_cmd_stdout = opts[:stdout] unless opts[:stdout].nil?
      node.last_cmd_stderr = opts[:stderr] unless opts[:stderr].nil?
      node.last_cmd_exit_status = opts[:status] unless opts[:status].nil?
      node.state = opts[:state] unless opts[:state].nil?
      @config.set_node_state(node.hostname,'','',opts[:node_state]) unless opts[:node_state].nil?
    end

    def nodes_init(opts={})
      @nodes.set.each do |node|
        node_set(node,opts)
      end
    end

    def nodes_array()
      ret = @nodes.make_sorted_array_of_nodes
      if @cluster_config.use_ip_to_deploy then
        ret.collect { |node| node.ip }
      else
        ret.collect { |node| node.hostname }
      end
      ret
    end

    # Get a node object by it's host
    def node_get(host)
      ret = nil
      if @cluster_config.use_ip_to_deploy then
        ret = @nodes.get_node_by_ip(host)
      else
        ret = @nodes.get_node_by_host(host)
      end
      ret
    end

    # Get the identifier that allow to contact a node (hostname|ip)
    def get_nodeid(node,vlan=false)
      if vlan and !@config.exec_specific.vlan.nil?
        ret = @config.exec_specific.ip_in_vlan[node.hostname]
      else
        if (@cluster_config.use_ip_to_deploy) then
          ret = node.ip
        else
          ret = node.hostname
        end
      end
      ret
    end

    # Set information about a Taktuk command execution
    def nodes_update(result)
      res = result.compact!([:line]).group_by { |v| v[:host] }
      res.each_pair do |host,values|
        node = node_get(host)
        ret = []
        values.each do |value|
          if value[:line].is_a?(Array)
            ret += value[:line]
          else
            ret << value[:line]
          end
        end
        yield(node,ret)
      end
    end

    # Set information about a Taktuk command execution
    def nodes_updates(results)
      nodes_update(results[:output]) do |node,val|
        node.last_cmd_stdout = val.join("\\n")
      end
      nodes_update(results[:error]) do |node,val|
        node.last_cmd_stderr = val.join("\\n")
      end
      nodes_update(results[:status]) do |node,val|
        node.last_cmd_stderr = val[0]
      end
      nodes_update(results[:connector]) do |node,val|
        val.each do |v|
          if !(v =~ /^Warning:.*$/)
            node.last_cmd_exit_status = "256"
            node.last_cmd_stderr = "The node #{node.hostname} is unreachable"
            break
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

      connector = @config.common.taktuk_connector
      taktuk_opts[:connector] = connector unless connector.empty?

      taktuk_opts[:self_propagate] = nil if @config.common.taktuk_auto_propagate

      tree_arity = @config.common.taktuk_tree_arity
      case opts[:scattering]
      when :chain
        taktuk_opts[:dynamic] = 1
      when :tree
        taktuk_opts[:dynamic] = tree_arity if (tree_arity > 0)
      else
        raise "Invalid structure for broadcasting file"
      end

      taktuk(nodes_array(),taktuk_opts)
    end

    def do_taktuk(opts={})
      @taktuk = taktuk_init(opts)
      yield(@taktuk)
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
      nodes_init(:stdout => '', :stderr => 'Unreachable', :status => '256')

      res = nil
      do_taktuk do |tak|
        tak.broadcast_exec[command]
        tak.seq!.broadcast_input_file[opts[:input_file]] if opts[:input_file]
        res = tak.run!
        @output.debug("#{tak.binary} #{tak.args.inspect}", @nodes)
      end

      nodes_updates(res)
      nodes_sort(expects)
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
      do_taktuk do |tak|
        res = tak.broadcast_put[src][dst].run!
        @output.debug("#{tak.binary} #{tak.args.inspect}", @nodes)
      end

      nodes_updates(res)
      nodes_sort(expects)
    end

    # Test if a node accept or refuse connections on every ports of a list (TCP)
    def ports_test(nodeid, ports, accept=true)
      ret = true
      ports.each do |port|
        begin
          s = TCPsocket.open(nodeid, port)
          s.close
          unless accept
            ret = false
            break
          end
        rescue Errno::ECONNREFUSED
          if accept
            ret = false
            break
          end
        rescue Errno::EHOSTUNREACH
          ret = false
          break
        end
      end
      ret
    end

    # Wait for several nodes after a reboot command and wait a give time the effective reboot
    #
    # Arguments
    # * timeout: time to wait
    # * ports_up: array of ports that must be up on the rebooted nodes to test
    # * ports_down: array of ports that must be down on the rebooted nodes to test
    # * nodes_check_window: instance of WindowManager
    # * specify if the nodes are in a VLAN
    # Output
    # * returns an array that contains two arrays ([0] is the nodes OK and [1] is the nodes KO)
    def wait_nodes_after_reboot(timeout, ports_up, ports_down, nodes_check_window, vlan = false)
      nodes_init(
        :stdout => '',
        :stderr => 'Unreachable after the reboot',
        :state => 'KO',
        :node_state => 'reboot_in_progress',
      )

      start = Time.now.tv_sec
      sleep(20)

      t = eval(timeout).to_i

      while (((Time.now.tv_sec - start) < t) && (not @nodes.all_ok?))
        sleep(5)

        nodes_to_test = Nodes::NodeSet.new
        @nodes.set.each do |node|
          nodes_to_test.push(node) if node.state == 'KO'
        end

        nodes_check_window.launch_on_node_set(nodes_to_test) do |ns|
          @waitreboot_threads = ThreadGroup.new

          ns.set.each do |node|
            thr = Thread.new do
              nodeid = get_nodeid(node,vlan)

              if Ping.pingecho(nodeid, 1, @config.common.ssh_port) then
                unless ports_test(node,ports_up,true)
                  node.state = 'KO'
                  next
                end

                unless ports_test(node,ports_down,false)
                  node.state = 'KO'
                  next
                end

                node_set(
                  node,
                  :state => 'OK',
                  :status => '0',
                  :stderr => '',
                  :node_state => 'rebooted'
                )

                @output.verbosel(4,"  *** #{node.hostname} is here after #{Time.now.tv_sec - start}s",@nodes)
              end
            end
            @waitreboot_threads.add(thr)
          end

          #let's wait everybody
          @waitreboot_threads.list.each do |thr|
            thr.join
          end
        end
        nodes_to_test = nil
      end

      nodes_sort(:state => 'OK')
    end
  end
end
