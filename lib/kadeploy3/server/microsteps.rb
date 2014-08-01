require 'fileutils'
require 'socket'
require 'tempfile'

module Kadeploy

class Microstep < Automata::QueueTask
  attr_reader :output
  include Printer
  alias_method :__debug__, :debug

  def initialize(name, idx, subidx, nodes, nsid, manager_queue, output, context = {}, params = [])
    @output = output
    super(name, idx, subidx, nodes, nsid, manager_queue, context, params)
    @debugger = context[:debugger]
    @runthread = nil
    @current_operation = nil
    @waitreboot_threads = ThreadGroup.new
    @timestart = Time.now.to_i
    @done = false
    @lock = Mutex.new
  end

  def debug(level,msg,info=true,opts={})
    if info
      msg = "   * #{msg}"
    elsif !info.nil?
      msg = "  #{msg}"
    end
    __debug__(level,msg,nsid(),opts)
  end

  def run()
    @runthread = Thread.current
    ret = true

    @nodes.set.each do |node|
      context[:states].set(
        node.hostname,
        context[:local][:parent].name.to_s,
        @name.to_s,
        "ok"
      )
      node.last_cmd_stdout = ''
      node.last_cmd_stderr = ''
      node.last_cmd_exit_status = -1
    end

    begin
      if ret
        @timestart = Time.now.to_i
        if @name.to_s =~ /^custom_sub_.*$/
          debug(3,"#{@name.to_s.sub(/^custom_sub_/,'')}",false)
          ret = ret && send(:custom,*@params)
        elsif @name.to_s =~ /^custom_pre_.*$/
          debug(3,"#{@name.to_s.sub(/^custom_pre_/,'')}",false)
          ret = ret && send(:custom,*@params)
        elsif @name.to_s =~ /^custom_post_.*$/
          debug(3,"#{@name.to_s.sub(/^custom_post_/,'')}",false)
          ret = ret && send(:custom,*@params)
        else
          debug(3,"#{@name.to_s}",false)
          ret = ret && send("ms_#{@name.to_s}".to_sym,*@params)
        end
        debug(4, " ~ Time in #{@name.to_s}: #{Time.now.to_i - @timestart}s",false)
      end
    rescue KadeployError => ke
      ke.context = context() unless ke.context
      raise ke
    end

    if ret
      @nodes.diff(@nodes_ko).linked_copy(@nodes_ok)
    else
      @nodes.linked_copy(@nodes_ko)
    end

    @done = true

    ret
  end

  def status
    {
      :nodes => {
        :OK => @nodes_ok.make_array_of_hostname,
        :KO => @nodes_ko.make_array_of_hostname,
        :'**' => @nodes.diff(@nodes_ok).diff(@nodes_ko).make_array_of_hostname,
      },
      :time => (Time.now.to_i - @timestart),
    }
  end

  def done?()
    (@done.nil? ? true : @done)
  end

  def kill(dofree=true)
    @waitreboot_threads.list.each do |thr|
      thr.kill if thr.alive?
    end
    @lock.synchronize do
      @current_operation.kill unless @current_operation.nil?

      unless @runthread.nil? # Waits for @runthread to finish
        timestart = Time.now
        while ((Time.now - timestart) < 4) and @runthread.alive? do
          sleep 0.5
        end

        if @runthread.alive?
          @runthread.kill
        else
          begin
            @runthread.join
          rescue SignalException
          end
        end
      end

      @done = true
    end

    free() if dofree
  end

  def free
    super()
    @output = nil
    @debugger = nil
    @current_operation.free if @current_operation
    @waitreboot_threads = nil
    @timestart = nil
    @done = nil
  end

  private

  # Get the identifier that allow to contact a node (hostname|ip)
  def get_nodeid(node,vlan=false)
    if vlan and !context[:execution].vlan_id.nil?
      ret = context[:execution].vlan_addr[node.hostname]
    else
      if context[:cluster].use_ip_to_deploy
        ret = node.ip
      else
        ret = node.hostname
      end
    end
    ret
  end

  def get_nodeobj(nodes,str)
    ret = nil
    if context[:cluster].use_ip_to_deploy then
      ret = nodes.get_node_by_ip(str)
    else
      ret = nodes.get_node_by_host(str)
    end
    ret
  end

  def init_nodes(opts={})
    @nodes.set.each do |node|
      set_node(node,opts)
    end
  end

  def set_node(node,opts={})
    node.last_cmd_stdout = opts[:stdout] unless opts[:stdout].nil?
    node.last_cmd_stderr = opts[:stderr] unless opts[:stderr].nil?
    node.last_cmd_exit_status = opts[:status] unless opts[:status].nil?
    node.state = opts[:state] unless opts[:state].nil?
    context[:states].set(node.hostname,'','',opts[:node_state]) unless opts[:node_state].nil?
  end

  def failed_microstep(msg)
    debug(0, "Error[#{@name.to_s}] #{msg}")
    @nodes.set_error_msg(msg)
    @nodes.linked_copy(@nodes_ko)
    @nodes_ko.set.each do |n|
      set_node(n, :state => 'KO', :node_state => 'ko')
    end
  end


  # Classify an array of nodes in two NodeSet (good ones and bad nodes)
  #
  # Arguments
  # * good_bad_array: array that contains nodes ok and ko ([0] are the good ones and [1] are the bad ones)
  # Output
  # * nothing
  def classify_nodes(good_bad_array)
    if not good_bad_array[0].empty? then
      good_bad_array[0].each { |n|
        @nodes_ok.push(n)
      }
    end
    if not good_bad_array[1].empty? then
      good_bad_array[1].each { |n|
        debug(5, "The node #{n.hostname} has been discarded of the current instance")
        set_node(n, :state => 'KO', :node_state => 'ko')
        @nodes_ok.remove(n)
        @nodes_ko.push(n)
      }
    end
  end

  # Classify an array of nodes in two NodeSet (good ones and bad nodes) but does not modify @nodes_ko
  #
  # Arguments
  # * good_bad_array: array that contains nodes ok and ko ([0] are the good ones and [1] are the bad ones)
  # Output
  # * return a NodeSet of bad nodes or nil if there is no bad nodes
  def classify_only_good_nodes(good_bad_array)
    if not good_bad_array[0].empty? then
      good_bad_array[0].each { |n|
        @nodes_ok.push(n)
      }
    end
    if not good_bad_array[1].empty? then
      bad_nodes = Nodes::NodeSet.new
      good_bad_array[1].each { |n|
        bad_nodes.push(n)
      }
      return bad_nodes
    else
      return nil
    end
  end

  def command(cmd,opts={},&block)
    raise '@current_operation should not be set' if @current_operation
    res = nil
    @lock.synchronize{ @current_operation = Execute[cmd] }
    @current_operation.run(opts)
    res = @current_operation.wait(opts)
    yield(*res) if block_given?
    @lock.synchronize do
      @current_operation.free
      @current_operation = nil
    end
    (res[0].exitstatus == 0)
  end

  def parallel_op(obj)
    raise '@current_operation should not be set' if @current_operation
    @lock.synchronize{ @current_operation = obj }
    yield(obj)
    @lock.synchronize do
      @current_operation.free
      @current_operation = nil
    end
  end

  # Wrap a parallel command
  #
  # Arguments
  # * cmd: command to execute on nodes_ok
  # * taktuk_connector: specifies the connector to use with Taktuk
  # * window: WindowManager instance, eventually used to launch the command
  # Output
  # * return true if the command has been successfully ran on one node at least, false otherwise
  # TODO: scattering kind
  def parallel_exec(cmd, opts={}, expects={}, window=nil)
    node_set = Nodes::NodeSet.new
    if @nodes_ok.empty?
      @nodes.linked_copy(node_set)
    else
      @nodes_ok.linked_copy(node_set)
    end

    do_exec = lambda do |nodeset|
      res = nil
      parallel_op(
        ParallelOperation.new(
          nodeset,
          context,
          @debugger
        )
      ) do |op|
        res = op.taktuk_exec(cmd,opts,expects)
      end
      classify_nodes(res)
    end

    if window then
      window.launch_on_node_set(node_set,&do_exec)
    else
      do_exec.call(node_set)
    end

    return (not @nodes_ok.empty?)
  end

  # Wrap a parallel send of file
  #
  # Arguments
  # * file: file to send
  # * dest_dir: destination of the file on the nodes
  # * scattering_kind: kind of taktuk scatter (tree, chain)
  # * taktuk_connector: specifies the connector to use with Taktuk
  # Output
  # * return true if the file has been successfully sent on one node at least, false otherwise
  # TODO: scattering kind
  def parallel_sendfile(src_file, dest_dir, opts={})
    nodeset = Nodes::NodeSet.new
    if @nodes_ok.empty?
      @nodes.linked_copy(nodeset)
    else
      @nodes_ok.linked_copy(nodeset)
    end

    res = nil
    parallel_op(
      ParallelOperation.new(
        nodeset,
        context,
        @debugger
      )
    ) do |op|
      res = op.taktuk_sendfile(src_file,dest_dir,opts)
    end
    classify_nodes(res)

    return (not @nodes_ok.empty?)
  end

  def parallel_run(nodeset_id)
    raise unless block_given?
    parallel_op(ParallelRunner.new(@debugger,nodeset_id)) do |op|
      yield(op)
    end
  end

  # Wrap a parallel command to get the power status
  #
  # Arguments
  # * instance_thread: thread id of the current thread
  # Output
  # * return true if the power status has been reached at least on one node, false otherwise
  def parallel_get_power_status()
    node_set = Nodes::NodeSet.new
    if @nodes_ok.empty?
      @nodes.linked_copy(node_set)
    else
      @nodes_ok.linked_copy(node_set)
    end
    debug(3, "A power status will be performed")

    res = nil
    parallel_run(node_set.id) do |pr|
      node_set.set.each do |node|
        if node.cmd.power_status
          pr.add(Nodes::NodeCmd.generate(node.cmd.power_status,node),node)
        elsif context[:cluster].cmd_power_status
          pr.add(Nodes::NodeCmd.generate(context[:cluster].cmd_power_status,node),node)
        else
          set_node(node, :stderr => 'power_status command is not provided')
          @nodes_ko.push(node)
        end
      end
      pr.run
      pr.wait
      res = pr.get_results
    end
    classify_nodes(res)
    @nodes_ok.set.each do |node|
      context[:states].set(node.hostname,nil,nil,nil,nil,node.last_cmd_stdout)
    end
    return (not @nodes_ok.empty?)
  end

  # Replace a group of nodes in a command
  #
  # Arguments
  # * str: command that contains the patterns GROUP_FQDN or GROUP_SHORT 
  # * array_of_hostname: array of hostnames
  # Output
  # * return a string with the patterns replaced by the hostnames
  def replace_groups_in_command(str, array_of_hostname)
    fqdn_hosts = array_of_hostname.join(",")
    short_hosts_array = Array.new
    array_of_hostname.each { |host|
      short_hosts_array.push(host.split(".")[0])
    }
    short_hosts = short_hosts_array.join(",")
    if (str != nil) then
      cmd_to_expand = str.clone # we must use this temporary variable since sub() modify the strings
      save = str
      while cmd_to_expand.sub!("GROUP_FQDN", fqdn_hosts) != nil  do
        save = cmd_to_expand
      end
      while cmd_to_expand.sub!("GROUP_SHORT", short_hosts) != nil  do
        save = cmd_to_expand
      end
      return save
    else
      return nil
    end
  end

  # Sub function for ecalation_cmd_wrapper
  #
  # Arguments
  # * kind: kind of command to perform (reboot, power_on, power_off)
  # * level: start level of the command (soft, hard, very_hard)
  # * node_set: NodeSet
  # * initial_node_set: initial NodeSet
  # Output
  # * nothing
  def _escalation_cmd_wrapper(kind, level, node_set, initial_node_set)
    debug(3, "Performing a #{level} #{kind} on #{node_set.to_s_fold}")

    #First, we remove the nodes without command
    no_command_provided_nodes = Nodes::NodeSet.new
    to_remove = Array.new
    node_set.set.each { |node|
      if !node.cmd.instance_variable_get("@#{kind}_#{level}") and !context[:cluster].instance_variable_get("@cmd_#{kind}_#{level}")
        set_node(node, :stderr => "#{level}_#{kind} command is not provided")
        debug(3, " ! No #{level} #{kind} command is defined for #{node.hostname}",false)
        no_command_provided_nodes.push(node)
        to_remove.push(node)
      end
    }
    to_remove.each { |node|
      node_set.remove(node)
    }


    final_node_array = Array.new
    #Then, we check if there are grouped commands
    missing_dependency = false
    if context[:cluster].group_of_nodes.has_key?("#{level}_#{kind}") then
      node_set.set.each { |node|
        if (not missing_dependency) then
          node_found_in_final_array = false
          final_node_array.each { |entry|
            if entry.is_a?(String) then
              if node.hostname == entry then
                node_found_in_final_array = true
                break
              end
            elsif entry.is_a?(Array) then
              node_found_in_final_array = false
              entry.each { |hostname|
                if node.hostname == hostname then
                  node_found_in_final_array = true
                  break
                end
              }
              break if node_found_in_final_array
            end
          }

          if not node_found_in_final_array then
            node_found_in_group = false
            dependency_group = nil
            context[:cluster].group_of_nodes["#{level}_#{kind}"].each { |group|
              #The node belongs to a group
              node_found_in_group = false
              dependency_group = group
              if group.include?(node.hostname) then
                node_found_in_group = true
                all_nodes_of_the_group_found = true
                group.each { |hostname|
                  if (initial_node_set.get_node_by_host(hostname) == nil) then
                    all_nodes_of_the_group_found = false
                    break
                  end
                }
                if all_nodes_of_the_group_found then
                  final_node_array.push(group)
                  missing_dependency = false
                else
                  missing_dependency = true
                end
                break
              end
              break if node_found_in_group
            }
            final_node_array.push(node.hostname) if not node_found_in_group
            if missing_dependency then
              debug(3, "The #{level} #{kind} command cannot be performed since the node #{node.hostname} belongs to the following group of nodes [#{dependency_group.join(",")}] and all the nodes of the group are not in involved in the command")
              break
            end
          end
        else
          break
        end
      }
    else
      final_node_array = node_set.make_array_of_hostname
    end

    #We remove the grouped nodes previously ok
    final_node_array.each { |entry|
      if entry.is_a?(Array) then
        entry.each { |hostname|
          @nodes_ok.remove(initial_node_set.get_node_by_host(hostname))
        }
      end
    }

    backup_of_final_node_array = final_node_array.clone

    #Finally, fire !!!!!!!!
    bad_nodes = Nodes::NodeSet.new
    if not final_node_array.empty?
      context[:windows][:reboot].launch_on_node_array(final_node_array) do |na|
        res = nil
        parallel_run(node_set.id) do |pr|
          na.each do |entry|
            node = nil
            if entry.is_a?(String) then
              node = initial_node_set.get_node_by_host(entry)
            elsif entry.is_a?(Array) then
              node = initial_node_set.get_node_by_host(entry[0])
            else
              raise "Invalid entry in array"
            end
            cmd = node.cmd.instance_variable_get("@#{kind}_#{level}")
            cmd = context[:cluster].instance_variable_get("@cmd_#{kind}_#{level}") unless cmd
            cmd = Nodes::NodeCmd.generate(cmd,node)
            cmd = replace_groups_in_command(cmd, entry) if entry.is_a?(Array)
            pr.add(cmd, node)
          end
          pr.run
          pr.wait
          res = pr.get_results
        end
        ret = classify_only_good_nodes(res)
        bad_nodes.add(ret) if ret != nil
      end
    end

    #We eventually copy the status of grouped nodes
    backup_of_final_node_array.each do |entry|
      if entry.is_a?(Array) then
        ref_node = initial_node_set.get_node_by_host(entry[0])
        (1...(entry.length)).each do |index|
          node = initial_node_set.get_node_by_host(entry[index])
          set_node(node,
            :stdout => ref_node.last_cmd_stdout,
            :stderr => ref_node.last_cmd_stderr,
            :status => ref_node.last_cmd_exit_status
          )
          if (ref_node.last_cmd_exit_status == "0") then
            @nodes_ok.push(node)
          else
            bad_nodes.push(node)
          end
        end
      end
    end

    if bad_nodes.empty? then
      if no_command_provided_nodes.empty? then
        bad_nodes.free(false)
        no_command_provided_nodes.free(false)
        return nil
      else
        bad_nodes.free(false)
        return no_command_provided_nodes
      end
    else
      bad_nodes.add(no_command_provided_nodes) unless no_command_provided_nodes.empty?
      no_command_provided_nodes.free(false)
      return bad_nodes
    end
  end

  # Wrap an escalation command
  #
  # Arguments
  # * kind: kind of command to perform (reboot, power_on, power_off)
  # * level: start level of the command (soft, hard, very_hard)
  # Output
  # * nothing 
  def escalation_cmd_wrapper(kind, level)
    node_set = Nodes::NodeSet.new(@nodes.id)
    initial_node_set = Nodes::NodeSet.new(@nodes.id)
    if @nodes_ok.empty?
      @nodes.linked_copy(node_set)
    else
      @nodes_ok.linked_copy(node_set)
    end
    node_set.linked_copy(initial_node_set)

    map = Array.new
    map.push("soft")
    map.push("hard")
    map.push("very_hard")
    index = map.index(level)
    finished = false

    while ((index < map.length) && (not finished))
      bad_nodes = _escalation_cmd_wrapper(kind, map[index], node_set, initial_node_set)
      if bad_nodes
        node_set.delete
        index = index + 1
        if index < map.length
          bad_nodes.move(node_set)
        else
          @nodes_ko.add(bad_nodes)
        end
      else
        finished = true
      end
      bad_nodes.free(false) if bad_nodes
    end

    map.clear
    map = nil
    node_set.free(false)
    node_set = nil
    initial_node_set = nil
  end

  # Test if the given symlink is an absolute link
  #
  # Arguments
  # * link: link
  # Output
  # * return true if link is an aboslute link, false otherwise
  def is_absolute_link?(link)
    return (/\A\/.*\Z/ =~ link)
  end

  # Test if the given symlink is a relative link
  #
  # Arguments
  # * link: link
  # Output
  # * return true if link is a relative link, false otherwise
  def is_relative_link?(link)
    return (/\A(\.\.\/)+.*\Z/ =~ link)
  end

  # Get the number of ../ groups at the beginning of a string
  #
  # Arguments
  # * str: string
  # Output
  # * return the number of ../ groups at the beginning of str
  def get_nb_dotdotslash(str)
    /\A((\.\.\/)+).*\Z/  =~ str
    content = Regexp.last_match
    return content[1].length / 3
  end

  #
  # Remove a given number of subdirs in a dirname
  #
  # Arguments
  # * dir: dirname
  # * nb: number of subdirs to remove
  # Output
  # * return a dirname on which nb subdirs have been removed
  def remove_sub_paths(dir, nb)
    tmp = dir
    while (nb > 0)
      pos = tmp.rindex("/")
      if (pos != nil) then
        tmp = tmp[0, pos]
      else
        tmp = ""
      end
      nb = nb - 1
    end
    return tmp
  end

  # Remove the ../ at the beginning of a string
  #
  # Arguments
  # * str: string
  # Output
  # * return a string without the ../ characters at the beginning
  def remove_dotdotslash(str)
    /\A(\.\.\/)+(.*)\Z/  =~ str
    content = Regexp.last_match
    return content[2]
  end

  # Extract some file from an archive
  #
  # Arguments
  # * archive: archive name
  # * archive_kind: kind of archive
  # * file_array: array of file to extract from the archive
  # * dest_dir: destination dir for the files extracted
  # Output
  # * return true if the file are extracted correctly, false otherwise
  def extract_files_from_archive(archive, archive_kind, file_array, dest_dir)
    opts = context[:common].tar_options
    file_array.each { |file|
      all_links_followed = false
      initial_file = file
      while (not all_links_followed)
        case archive_kind
        when "tgz"
          cmd = "tar #{opts} -C #{dest_dir} -xzf #{archive} #{file}"
        when "tbz2"
          cmd = "tar #{opts} -C #{dest_dir} -xjf #{archive} #{file}"
        when "txz"
          cmd = "tar #{opts} -C #{dest_dir} -xJf #{archive} #{file}"
        else
          raise "The kind #{archive_kind} of archive is not supported"
        end
        if not command(cmd) then
          failed_microstep("The file #{file} cannot be extracted")
          return false
        end
        if File.symlink?(File.join(dest_dir, file)) then
          link = File.readlink(File.join(dest_dir, file))
          if is_absolute_link?(link) then
            file = link.sub(/\A\//,"")
          elsif is_relative_link?(link) then
            base_dir = remove_sub_paths(File.dirname(file), get_nb_dotdotslash(link))
            file = File.join(base_dir, remove_dotdotslash(link)).sub(/\A\//,"")
          else
            dirname = File.dirname(file)
            if (dirname == ".") then
              file = link
            else
              file = File.join(dirname.sub(/\A\.\//,""),link)
            end
          end
        else
          all_links_followed = true
        end
      end
      dest = File.basename(initial_file)
      if (file != dest) then
        if not command("mv #{File.join(dest_dir,file)} #{File.join(dest_dir,dest)}") then
          failed_microstep("Cannot move the file #{File.join(dest_dir,file)} to #{File.join(dest_dir,dest)}")
          return false
        end
      end
    }
    return true
  end

=begin
  # Copy the kernel and the initrd into the PXE directory
  #
  # Arguments
  # * files_array: array of file
  # Output
  # * return true if the operation is correctly performed, false
  def copy_kernel_initrd_to_pxe(files_array)
    files = Array.new
    files_array.each { |f|
      files.push(f.sub(/\A\//,'')) if (f != nil)
    }
    must_extract = false
    archive = context[:execution].environment.image[:file]
    dest_dir = File.join(context[:common].pxe_repository, context[:common].pxe_repository_kernels)
    files.each { |file|
      if not (File.exist?(File.join(dest_dir, context[:execution].prefix_in_cache + File.basename(file)))) then
        must_extract = true
      end
    }
    if not must_extract then
      files.each { |file|
        #If the archive has been modified, re-extraction required
        if (File.mtime(archive).to_i > File.atime(File.join(dest_dir, context[:execution].prefix_in_cache + File.basename(file))).to_i) then
          must_extract = true
        end
      }
    end
    if must_extract then
      files_in_archive = Array.new
      files.each { |file|
        files_in_archive.push(file)
      }
      tmpdir = get_tmpdir()
      if not extract_files_from_archive(archive,
                                        context[:execution].environment.image[:shortkind],
                                        files_in_archive,
                                        tmpdir) then
        failed_microstep("Cannot extract the files from the archive")
        return false
      end
      files_in_archive.clear
      files.each { |file|
        src = File.join(tmpdir, File.basename(file))
        dst = File.join(dest_dir, context[:execution].prefix_in_cache + File.basename(file))
        if not command("mv #{src} #{dst}") then
          failed_microstep("Cannot move the file #{src} to #{dst}")
          return false
        end
      }
      if not command("rm -rf #{tmpdir}") then
        failed_microstep("Cannot remove the temporary directory #{tmpdir}")
        return false
      end
      return true
    else
      return true
    end
  end
=end

  # Get the name of the deployment partition
  #
  # Arguments
  # * nothing
  # Output
  # * return the name of the deployment partition
  def get_block_device_str
    if (context[:execution].block_device != "") then
      context[:execution].block_device
    else
      context[:cluster].block_device
    end
  end

  def get_block_device_num
    get_block_device_str().strip[-1].ord - 'a'[0].ord
  end

  # Get the name of the deployment partition
  #
  # Arguments
  # * nothing
  # Output
  # * return the name of the deployment partition
  def get_deploy_part_str
    if context[:execution].deploy_part.nil?
      get_block_device_str
    elsif context[:execution].deploy_part != ""
      get_block_device_str + context[:execution].deploy_part
    else
      get_block_device_str + context[:cluster].deploy_part
    end
  end

  # Get the number of the deployment partition
  #
  # Arguments
  # * nothing
  # Output
  # * return the number of the deployment partition
  def get_deploy_part_num
    if context[:execution].deploy_part != ""
      return context[:execution].deploy_part.to_i
    else
      return context[:cluster].deploy_part.to_i
    end
  end

  # Get the kernel parameters
  #
  # Arguments
  # * nothing
  # Output
  # * return the kernel parameters
  def get_kernel_params
    #We first check if the kernel parameters are defined in the environment
    if !context[:execution].environment.kernel_params.nil? and !context[:execution].environment.kernel_params.empty?
      context[:execution].environment.kernel_params
    #Otherwise we eventually check in the cluster specific configuration
    elsif !context[:cluster].kernel_params.nil?
      context[:cluster].kernel_params
    else
      ''
    end
  end

  def get_decompress_cmd(kind,directory,partition=nil,input_file=nil,output_file=nil)
    if output_file
      "cat #{(input_file ? input_file : '-')} > #{output_file}"
    else
      opts = context[:common].tar_options
      case kind
      when "tgz"
        "tar #{opts} -C #{directory} -xz#{"f #{input_file}" if input_file}"
      when "tbz2"
        "tar #{opts} -C #{directory} -xj#{"f #{input_file}" if input_file}"
      when "txz"
        "tar #{opts} -C #{directory} -xJ#{"f #{input_file}" if input_file}"
      when "ddgz"
        if partition
          "gzip -cd #{input_file if input_file} > #{partition}"
        else
          false
        end
      when "ddbz2"
        if partition
          "bzip2 -cd #{input_file if input_file} > #{partition}"
        else
          false
        end
      when "ddxz"
        if partition
          "xz -cd #{input_file if input_file} > #{partition}"
        else
          false
        end
      when /^fsa\d+$/
        if input_file
          nbcpu = "$(grep -c '^processor' /proc/cpuinfo)"

          comp = (
           context[:execution].environment.image[:compression].to_i > 0 \
            ? "-z #{context[:execution].environment.image[:compression]}" \
            : ''
          )

          fsmap = ''
          if context[:execution].environment.multipart
            context[:execution].environment.options['partitions'].each do |part|
              fsmap += "id=#{part['id'].to_s},dest=#{part['device']} "
            end
          else
            if partition
              if context[:execution].environment.options['partitions']
                part = context[:execution].environment.options['partitions'][0]
                fsmap += "id=#{part['id'].to_s},dest=#{partition} "
              else
                fsmap += "id=0,dest=#{partition}"
              end
            else
              false
            end
          end

          "fsarchiver -j #{nbcpu} #{comp} restfs #{input_file} #{fsmap}"
        else
          false
        end
      else
        false
      end
    end
  end

  def send_tarball_and_uncompress_with_custom(cmd, file, decompress)
    node_set = Nodes::NodeSet.new
    if @nodes_ok.empty?
      @nodes.linked_copy(node_set)
    else
      @nodes_ok.linked_copy(node_set)
    end

    cmd.gsub!("ENVFILE",file)
    nodefile = Tempfile.new("nodefile")
    node_set.make_sorted_array_of_nodes.each do |node|
      nodefile.puts(get_nodeid(node))
    end
    nodefile.close
    cmd.gsub!("NODEFILE",nodefile.path)
    cmd.gsub!("DECOMPRESS",decompress)
    cmd.gsub!("TAKTUK_CONNECTOR",context[:common].taktuk_connector)

    @nodes_ok.clean()
    status,out,err = nil
    command(cmd,
      :stdout_size => 1000,
      :stderr_size => 1000
    ) do |st,stdout,stderr|
      status = st.exitstatus
      out = stdout
      err = stderr
    end
    nodefile.unlink

    @debugger.push(cmd,@nodes,out,err,status) if @debugger
    if (status != 0) then
      failed_microstep("Error while processing to the file broadcast with #{File.basename(cmd.split(' ')[0])} (exited with status #{status})")
      return false
    else
      return true
    end
  end

  # Send a tarball with Taktuk and uncompress it on the nodes
  #
  # Arguments
  # * scattering_kind:  kind of taktuk scatter (tree, chain)
  # * tarball_file: path to the tarball
  # * tarball_kind: kind of archive (tgz, tbz2, ddgz, ddbz2)
  # * deploy_mount_point: deploy mount point
  # * deploy_mount_part: deploy mount part
  # Output
  # * return true if the operation is correctly performed, false otherwise
  def send_tarball_and_uncompress_with_taktuk(scattering_kind, file, decompress)
    return parallel_exec(
      decompress,
      { :input_file => file, :scattering => scattering_kind },
      { :status => ["0"] }
    )
  end

  # Send a tarball with Kastafior and uncompress it on the nodes
  #
  # Arguments
  # * file: path to the tarball
  # * decompress: the decompression command
  # Output
  # * return true if the operation is correctly performed, false otherwise
  def send_tarball_and_uncompress_with_kastafior(file, decompress)
    if context[:cluster].use_ip_to_deploy then
      node_set = Nodes::NodeSet.new
      if @nodes_ok.empty?
        @nodes.linked_copy(node_set)
      else
        @nodes_ok.linked_copy(node_set)
      end
      # Use a window not to flood ssh commands
      context[:windows][:reboot].launch_on_node_set(node_set) do |ns|
        res = nil
        parallel_run(ns.id) do |pr|
          ns.set.each do |node|
            #kastafior_hostname = node.ip
            cmd = "#{context[:common].taktuk_connector} #{node.ip} \"echo #{node.ip} > /tmp/kastafior_hostname\""
            pr.add(cmd, node)
          end
          pr.run
          pr.wait
          res = pr.get_results
        end
        classify_nodes(res)
      end

      begin
        File.open("/tmp/kastafior_hostname", "w") { |f|
          f.puts(Socket.gethostname())
        }
      rescue => e
        failed_microstep("Cannot write the kastafior hostname file on server: #{e}")
        return false
      end
    else
      @nodes.linked_copy(@nodes_ok)
    end

    nodefile = Tempfile.new("kastafior-nodefile")
    nodefile.puts(Socket.gethostname())

    @nodes_ok.make_sorted_array_of_nodes.each do |node|
      nodefile.puts(get_nodeid(node))
    end

    nodefile.close

    if context[:common].taktuk_auto_propagate then
      cmd = "#{context[:common].kastafior} -s -c \\\"#{context[:common].taktuk_connector}\\\"  -- -s \"cat #{file}\" -c \"#{decompress}\" -n #{nodefile.path}"
    else
      cmd = "#{context[:common].kastafior} -c \\\"#{context[:common].taktuk_connector}\\\" -- -s \"cat #{file}\" -c \"#{decompress}\" -n #{nodefile.path}"
    end

    @nodes_ok.clean()
    status,out,err = nil
    command(cmd,
      :stdout_size => 1000,
      :stderr_size => 1000
    ) do |st,stdout,stderr|
      status = st.exitstatus
      out = stdout
      err = stderr
    end

    @debugger.push(cmd,@nodes,out,err,status) if @debugger
    if (status != 0) then
      failed_microstep("Error while processing to the file broadcast with Kastafior (exited with status #{status})")
      return false
    else
      return true
    end
  end

  def send_tarball_and_uncompress_with_kascade(file, decompress)
    node_set = Nodes::NodeSet.new
    @nodes.linked_copy(node_set)

    nodefile = Tempfile.new("kascade-nodefile")

    node_set.make_sorted_array_of_nodes.each do |node|
      nodefile.puts(get_nodeid(node))
    end

    nodefile.close

    okfile = Tempfile.new("kascade-okfile")
    okfile.close
    kofile = Tempfile.new("kascade-kofile")
    kofile.close

    cmd = "#{context[:common].kascade} "+
          "-i #{file} -n #{nodefile.path} "+
          "-O '#{decompress}' "+
          "-S '#{context[:common].taktuk_connector}' "+
          "--ok #{okfile.path} "+
          "--ko #{kofile.path} "+
          "#{(context[:cluster].use_ip_to_deploy)?'-I ':''} "+
          "-D taktuk "+
          "-P '-d #{context[:common].taktuk_tree_arity}#{context[:common].taktuk_auto_propagate ? ' -s':''}' "+
          "#{context[:common].kascade_options}"

    @nodes_ok.clean()
    status,out,err = nil
    command(cmd,
      :stdout_size => 1000,
      :stderr_size => 1000
    ) do |st,stdout,stderr|
      status = st.exitstatus
      out = stdout
      err = stderr
    end

    if status == 0
      okfile.unlink
      kofile.unlink

      @debugger.push(cmd,@nodes,out,err,status) if @debugger

      node_set.linked_copy(@nodes_ok)

      return true
    else
      begin
        oknodes = YAML.load_file(okfile.path)
        okfile.unlink
        konodes = YAML.load_file(kofile.path)
        kofile.unlink
        raise if !oknodes.is_a?(Array) or !konodes.is_a?(Hash)
      rescue
        oknodes = []
        tmp = node_set.make_sorted_array_of_nodes.collect{|n| get_nodeid(n)}
        konodes = Hash[tmp.zip [err]*tmp.size]
        tmp = nil
      end

      node_set.set.each do |node|
        id = get_nodeid(node)
        node.last_cmd_stdout = out

        if oknodes.include?(id)
          node.last_cmd_stderr = err
          node.last_cmd_exit_status = 0

          @nodes_ok.push(node)
        elsif konodes.keys.include?(id)
          @nodes_ko.push(node)
          node.last_cmd_stderr = "KASCADE-ERROR: #{konodes[id].inspect}"
          node.last_cmd_exit_status = status
        else
          @debugger.push(cmd,node_set) if @debugger
          failed_microstep("Error while processing Kascade output files")
          return false
        end
      end
      oknodes.clear
      oknodes = nil
      konodes.clear
      konodes = nil
    end

    @debugger.push(cmd,node_set) if @debugger

    return true
  end

  # Send a tarball with Bittorrent and uncompress it on the nodes
  #
  # Arguments
  # * file: path to the tarball
  # * decompress: the decompression command
  # Output
  # * return true if the operation is correctly performed, false otherwise
  def send_tarball_and_uncompress_with_bittorrent(file, decompress)
    tmpfile = get_tmp_file(file)
    if not parallel_exec("rm -f #{tmpfile}*") then
      failed_microstep("Error while cleaning the /tmp")
      return false
    end
    torrent = "#{file}.torrent"
    btdownload_state = "/tmp/btdownload_state#{Time.now.to_f}"
    tracker_pid, tracker_port = Bittorrent::launch_tracker(btdownload_state)
    if not Bittorrent::make_torrent(file, context[:common].bt_tracker_ip, tracker_port) then
      failed_microstep("The torrent file (#{torrent}) has not been created")
      return false
    end
    if !context[:caches][:global] then
      seed_pid = Bittorrent::launch_seed(torrent, File.dirname(file))
    else
      seed_pid = Bittorrent::launch_seed(torrent, context[:caches][:global].directory)
    end
    if (seed_pid == -1) then
      failed_microstep("The seed of #{torrent} has not been launched")
      return false
    end
    if not parallel_sendfile(torrent, '/tmp', { :scattering => :tree }) then
      failed_microstep("Error while sending the torrent file")
      return false
    end
    if not parallel_exec(shell_detach("/usr/local/bin/bittorrent /tmp/#{File.basename(torrent)}")) then
      failed_microstep("Error while launching the bittorrent download")
      return false
    end
    sleep(20)
    expected_clients = @nodes.length
    if not Bittorrent::wait_end_of_download(context[:common].bt_download_timeout, torrent, context[:common].bt_tracker_ip, tracker_port, expected_clients) then
      failed_microstep("A timeout for the bittorrent download has been reached")
      begin
        Execute.kill_recursive(seed_pid)
      rescue Errno::ESRCH
      end
      return false
    end
    begin
      debug(3, "Shutdown the seed for #{torrent}")
      Execute.kill_recursive(seed_pid)
      debug(3, "Shutdown the tracker for #{torrent}")
      Execute.kill_recursive(tracker_pid)
    rescue Errno::ESRCH
    end
    command("rm -f #{btdownload_state}")

    if not parallel_exec(decompress) then
      failed_microstep("Error while uncompressing the tarball")
      return false
    end
    if not parallel_exec("rm -f #{tmpfile}*") then
      failed_microstep("Error while cleaning the /tmp")
      return false
    end
    return true
  end

  def run_script()
    "tmp=`mktemp` " \
    "&& chmod 755 ${tmp} " \
    "&& cat - > $tmp "\
    "&& #{set_env()} ${tmp}"
  end

  # Run a custom method
  def custom(op)
    case op[:action]
    when :exec
      debug(4,'Executing custom command')
      return parallel_exec("#{set_env()} && #{op[:command]}",{ :scattering => op[:scattering] })
    when :send
      debug(4,'Sending custom file')
      dest = File.join(op[:destination].dup,op[:filename].dup)
      deploy_context().each_pair do |key,val|
        dest.gsub!("$#{key}",val.to_s)
      end
      return parallel_sendfile(
        op[:file],
        dest,
        { :scattering => op[:scattering] }
      )
    when :run
      debug(4,'Executing custom script')
      return parallel_exec(
        run_script(),
        { :input_file => op[:file], :scattering => op[:scattering] }
      )
    else
      debug(0,"Invalid custom action '#{op[:action]}'")
      return false
    end
  end

  # Create a tmp directory
  #
  # Arguments
  # * nothing
  # Output
  # * return the path of the tmp directory
  def get_tmpdir
    path = `mktemp -d`.chomp
    return path
  end

  def self.load_deploy_context(vals={:env=>{},:parts=>{}})
    ret = {
      'KADEPLOY_CLUSTER' => vals[:cluster],
      'KADEPLOY_DEPLOY_PART' => vals[:deploy_part],
      'KADEPLOY_BLOCK_DEVICE' => vals[:block_device],
      'KADEPLOY_DEPLOY_PART_NUM' => vals[:parts][:deploy],
      'KADEPLOY_SWAP_PART_NUM' => vals[:parts][:swap],
      'KADEPLOY_PROD_PART_NUM' => vals[:parts][:prod],
      'KADEPLOY_TMP_PART_NUM' => vals[:parts][:tmp],
      'KADEPLOY_PREPOST_EXTRACTION_DIR' => vals[:prepostdir],
      'KADEPLOY_TMP_DIR' => vals[:tmpdir],
    }
    if vals[:env]
      ret['KADEPLOY_ENV'] = vals[:env][:name]
      ret['KADEPLOY_ENV_KERNEL'] = vals[:env][:kernel]
      ret['KADEPLOY_ENV_INITRD'] = vals[:env][:initrd]
      ret['KADEPLOY_ENV_KERNEL_PARAMS'] = vals[:env][:kernel_params]
      ret['KADEPLOY_ENV_HYPERVISOR'] = vals[:env][:hypervisor]
      ret['KADEPLOY_ENV_HYPERVISOR_PARAMS'] = vals[:env][:hypervisor_params]
      ret['KADEPLOY_OS_KIND'] = vals[:env][:kind]
    end
    ret['KADEPLOY_PART_TYPE'] = vals[:parttype] if vals[:parttype]
    ret['KADEPLOY_FS_TYPE'] = vals[:fstype] if vals[:fstype]
    ret['KADEPLOY_FS_TYPE_TMP'] = vals[:fstype_tmp] if vals[:fstype_tmp]
    ret['KADEPLOY_ENV_EXTRACTION_DIR'] = vals[:extractdir] if vals[:extractdir]

    ret
  end

  def deploy_context
    env = nil
    extractdir = nil
    parttype = nil
    fstype = nil
    if context[:execution].environment
      env = {
        :name => context[:execution].environment.name,
        :kind => context[:execution].environment.environment_kind,
        :kernel => context[:execution].environment.kernel,
        :initrd => context[:execution].environment.initrd,
        :kernel_params => get_kernel_params(),
        :hypervisor => context[:execution].environment.hypervisor,
        :hypervisor_params => context[:execution].environment.hypervisor_params,
      }
      extractdir = context[:common].environment_extraction_dir
      parttype = context[:execution].environment.fdisk_type
      fstype = context[:execution].environment.filesystem
    end
    self.class.load_deploy_context({
      :cluster => context[:cluster].name,
      :env => env,
      :deploy_part => get_deploy_part_str(),
      :block_device => get_block_device_str(),
      :parts => {
        :deploy => get_deploy_part_num(),
        :swap => context[:cluster].swap_part,
        :prod => context[:cluster].prod_part,
        :tmp => context[:cluster].tmp_part,
      },
      :extractdir => extractdir,
      :prepostdir => context[:common].rambin_path,
      :tmpdir => '/tmp',
      :parttype => parttype,
      :fstype => fstype,
      :fstype_tmp => context[:execution].reformat_tmp,
    })
  end

  # Create a string containing the environment variables for pre/post installs
  #
  # Arguments
  # * nothing
  # Output
  # * return the string containing the environment variables for pre/post installs
  def set_env
    ret = ''
    deploy_context().each_pair do |key,val|
      ret += "#{key.to_s}=\"#{val}\" "
    end
    ret
  end

  def get_tmp_file(file)
    File.join(context[:common].rambin_path,"_KATMP_#{File.basename(file)}")
  end

  def set_parttype(map,val,empty)
    map.gsub!(/PARTTYPE#{get_deploy_part_num()}(\D)/,"#{val}\\1") if val
    map.gsub!(/PARTTYPE\d+/,empty)
    map.gsub!('PARTTYPE',val || empty)
    map
  end

  # Perform a fdisk on the nodes
  #
  # Arguments
  # * env: kind of environment on wich the fdisk operation is performed
  # Output
  # * return true if the fdisk has been successfully performed, false otherwise
  def do_fdisk()
    begin
      temp = Tempfile.new("fdisk_#{context[:cluster].name}")
    rescue StandardError
      failed_microstep("Cannot create the fdisk tempfile")
      return false
    end

    map = File.read(context[:cluster].partition_file)
    map = set_parttype(map,context[:execution].environment.fdisk_type,'0')
    temp.write(map)
    temp.close

    unless parallel_exec(
      "fdisk #{get_block_device_str()}",
      { :input_file => temp.path, :scattering => :tree }
    )
      failed_microstep("Cannot perform the fdisk operation")
      return false
    end

    temp.unlink
    return true
  end

  # Perform a parted on the nodes
  #
  # Arguments
  # Output
  # * return true if the parted has been successfully performed, false otherwise
  def do_parted()
    map = File.read(context[:cluster].partition_file)
    map.gsub!("\n",' ')
    map = set_parttype(map, context[:execution].environment.filesystem, '')
    return parallel_exec(
      "parted -a optimal #{get_block_device_str()} --script #{map}",
      { :scattering => :tree }
    )
  end

  public

  def ms_dummy()
    sleep((200+rand(800)) / 1000.0)
    true
  end

  # Send the SSH key in the deployment environment
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain)
  # Output
  # * return true if the keys have been successfully copied, false otherwise
  def ms_send_key_in_deploy_env(scattering_kind)
    return parallel_exec(
      "cat - >>/root/.ssh/authorized_keys",
      { :input_file => context[:execution].key, :scattering => scattering_kind}
    )
  end

  # Change the PXE configuration
  #
  # Arguments
  # * step: kind of change (prod_to_deploy_env, prod_to_nfsroot_env, chainload_pxe)
  # * pxe_profile_msg (opt): string containing the pxe profile
  # Output
  # * return true if the operation has been performed correctly, false otherwise
  def ms_switch_pxe(step, pxe_profile = "")
    get_nodes = lambda do |check_vlan|
      @nodes.set.collect do |node|
        n = { :hostname => node.hostname }
        if check_vlan && !context[:execution].vlan_id.nil?
          n[:ip] = context[:execution].vlan_addr[node.hostname]
        else
          n[:ip] = node.ip
        end
        n
      end
    end

    case step
    when "prod_to_deploy_env"
      unless context[:common].pxe[:network].boot(
        :network,
        get_nodes.call(false),
        context[:cluster].pxe_header,
        context[:cluster].deploy_kernel,
        context[:cluster].deploy_initrd,
        context[:cluster].deploy_kernel_args
      ) then
        failed_microstep("Cannot perform the set_pxe_for_deploy operation")
        return false
      end
    when "prod_to_nfsroot_env"
      unless context[:common].pxe[:network].boot(
        :network,
        get_nodes.call(false),
        context[:cluster].pxe_header,
        context[:cluster].nfsroot_kernel,
        nil,
        context[:cluster].nfsroot_params
      ) then
        failed_microstep("Cannot perform the set_pxe_for_nfsroot operation")
        return false
      end
    when "set_pxe"
      unless context[:common].pxe[:dhcp].boot(
        :custom,
        get_nodes.call(false),
        context[:cluster].pxe_header,
        pxe_profile,
        context[:execution].user,
        context[:wid],
        context[:execution].pxe[:singularities]
      ) then
        failed_microstep("Cannot perform the set_pxe_for_custom operation")
        return false
      end
    when "deploy_to_deployed_env"
      p = Proc.new { |nodes|
        if context[:execution].pxe and context[:execution].pxe[:profile]
          unless context[:common].pxe[:dhcp].boot(
            :custom,
            nodes,
            context[:cluster].pxe_header,
            context[:execution].pxe[:profile],
            context[:execution].user,
            context[:wid],
            context[:execution].pxe[:singularities]
          ) then
            failed_microstep("Cannot perform the set_pxe_for_custom operation")
            return false
          end
        else
          unless context[:common].pxe[:local].boot(
            :local,
            nodes,
            context[:cluster].pxe_header,
            context[:execution].environment,
            get_block_device_str(),
            get_block_device_num(),
            context[:execution].boot_part || get_deploy_part_num(),
            context[:cluster].kernel_params
          ) then
            failed_microstep("Cannot perform the set_pxe_for_local operation")
            return false
          end
        end
      }
      #We have to generate PXE profiles for both production and VLAN networks if --vlan switch is used
      p.call(get_nodes.call(true)) if context[:execution].vlan_id
      p.call(get_nodes.call(false))
    end
    return true
  end

  # Perform a reboot on the current set of nodes_ok
  #
  # Arguments
  # * reboot_kind: kind of reboot (soft, hard, very_hard)
  # * first_attempt (opt): specify if it is the first attempt or not 
  # Output
  # * return true (should be false sometimes :D)
  def ms_reboot(reboot_kind)
    first_attempt = nil
    if context[:local][:parent].is_a?(Automata::Task)
      first_attempt = (context[:local][:parent].context[:local][:retries] == 0)
    else
      first_attempt = true
    end

    case reboot_kind
    when "soft"
      if first_attempt then
        escalation_cmd_wrapper("reboot", "soft")
      else
        #After the first attempt, we must not perform another soft reboot in order to avoid loop reboot on the same environment 
        escalation_cmd_wrapper("reboot", "hard")
      end
    when "hard"
      escalation_cmd_wrapper("reboot", "hard")
    when "very_hard"
      escalation_cmd_wrapper("reboot", "very_hard")
    end
    return true
  end

  # Perform a kexec reboot on the current set of nodes_ok
  #
  # Arguments
  # * systemking: the kind of the system to boot ('linux', ...)
  # * systemdir: the directory of the filesystem containing the system to boot
  # * kernelfile: the (local to 'systemdir') path to the kernel image
  # * initrdfile: the (local to 'systemdir') path to the initrd image
  # * kernelparams: the commands given to the kernel when booting
  # Output
  # * return false if the kexec execution failed
  def ms_kexec( systemkind, systemdir, kernelfile, initrdfile, kernelparams)
    if (systemkind == "linux") then

      tmpfile = Tempfile.new('kexec')
      tmpfile.write(shell_kexec(
        kernelfile,
        initrdfile,
        kernelparams,
        systemdir
      ))
      tmpfile.close

      ret = parallel_exec(
        "/bin/bash -se",
        { :input_file => tmpfile.path, :scattering => :tree }
      )

      ret = ret && parallel_exec(shell_detach('/sbin/reboot'))

      tmpfile.unlink

      return ret
    else
      debug(3, "   The Kexec optimization can only be used with a linux environment")
      return false
    end
  end

  # Check the kernel files on the nodes
  #
  # Output
  # * return false if one file is missing
  def ms_check_kernel_files()
    envkernel = context[:execution].environment.kernel
    envinitrd = context[:execution].environment.initrd
    envdir = context[:common].environment_extraction_dir

    tmpfile = Tempfile.new('kernel_check')
    tmpfile.write(
      "kernel=#{shell_follow_symlink(envkernel,envdir)}\n"\
      "initrd=#{shell_follow_symlink(envinitrd,envdir)}\n"\
      "test -e \"$kernel\" || (echo \"Environment kernel file #{envkernel} not found in tarball (${kernel})\" 1>&2; false)\n"\
      "test -e \"$initrd\" || (echo \"Environment initrd file #{envinitrd} not found in tarball (${initrd})\" 1>&2; false)\n"
    )
    tmpfile.close

    return parallel_exec(
      "/bin/bash -se",
      { :input_file => tmpfile.path, :scattering => :tree }
    )
  end

  # Get the shell command used to execute then detach a command
  #
  # Arguments
  # * cmd: the command
  # Output
  # * return a string that describe the shell command to be executed
  def shell_detach(cmd)
    "nohup /bin/sh -c 'sleep 1; #{cmd}' 1>/dev/null 2>/dev/null </dev/null &"
  end

  # Get the shell command used to reboot the nodes with kexec
  #
  # Arguments
  # * kernel: the path to the kernel image
  # * initrd: the path to the initrd image
  # * kernel_params: the commands given to the kernel when booting
  # * prefixdir: if specified, the 'kernel' and 'initrd' paths will be prefixed by 'prefixdir'
  # Output
  # * return a string that describe the shell command to be executed
  def shell_kexec(kernel,initrd,kernel_params='',prefixdir=nil)
    "kernel=#{shell_follow_symlink(kernel,prefixdir)} "\
    "&& initrd=#{shell_follow_symlink(initrd,prefixdir)} "\
    "&& /sbin/kexec "\
      "-l $kernel "\
      "--initrd=$initrd "\
      "--append=\"#{kernel_params}\" "
  end

  # Get the shell command used to follow a symbolic link until reaching the real file 
  # such as inside of chroot prefix.
  # * filename: the file
  # * prefixpath: if specified, follow the link as if chrooted in 'prefixpath' directory
  def shell_follow_symlink(filename,prefixpath=nil)
    "$("\
      "prefix=#{(prefixpath and !prefixpath.empty? ? prefixpath : '')} "\
      "&& file=#{filename} "\
      "&& while test -L ${prefix}$file; "\
      "do "\
        "tmp=`"\
          "stat ${prefix}$file --format='%N' "\
          "| sed "\
            "-e 's/^.*->\\ *\\(.[^\\ ]\\+.\\)\\ *$/\\1/' "\
            "-e 's/^.\\(.\\+\\).$/\\1/'"\
        "` "\
        "&& echo $tmp | grep '^/.*$' &>/dev/null "\
          "&& dir=`dirname $tmp` "\
          "|| dir=`dirname $file`/`dirname $tmp` "\
        "&& dir=`cd ${prefix}$dir; pwd -P` "\
        "&& dir=`echo $dir | sed -e \"s\#${prefix}##g\"` "\
        "&& file=$dir/`basename $tmp`; "\
      "done "\
      "&& echo ${prefix}/$file"\
    ")"
  end

  # Send the deploy kernel files to an environment kexec repository
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain, kastafior)
  # Output
  # * return true if the kernel files have been sent successfully
  def ms_send_deployment_kernel(scattering_kind)
    pxedir = context[:common].pxe[:network].repository_dir

    ret = parallel_exec("mkdir -p #{context[:cluster].kexec_repository}")

    ret = ret && parallel_sendfile(
      File.join(pxedir,context[:cluster].deploy_kernel),
      context[:cluster].kexec_repository,
      { :scattering => scattering_kind }
    )

    ret = ret && parallel_sendfile(
      File.join(pxedir,context[:cluster].deploy_initrd),
      context[:cluster].kexec_repository,
      { :scattering => scattering_kind }
    )

    return ret
  end

  # Perform a detached reboot from the deployment environment
  #
  # Arguments
  # Output
  # * return true if the reboot has been successfully performed, false otherwise
  def ms_reboot_from_deploy_env()
    return parallel_exec(shell_detach('/sbin/reboot -f'), {},{}, context[:windows][:reboot])
  end

  # Perform a power operation on the current set of nodes_ok
  def ms_power(operation, level)
    case operation
    when :on
      escalation_cmd_wrapper("power_on", level)
    when :off
      escalation_cmd_wrapper("power_off", level)
    when :status
      parallel_get_power_status()
    end
    return true
  end

  # Check the state of a set of nodes
  #
  # Arguments
  # * step: step in which the nodes are expected to be
  # Output
  # * return true if the check has been successfully performed, false otherwise
  def ms_check_nodes(step)
    case step
    when "deployed_env_booted"
      #we look if the / mounted partition is the deployment partition
      return parallel_exec(
        "(mount | grep \\ \\/\\  | cut -f 1 -d\\ )",
        {},
        { :stdout => get_deploy_part_str() }
      )
    when "prod_env_booted"
      #We look if the / mounted partition is the default production partition.
      #We don't use the Taktuk method because this would require to have the deploy
      #private key in the production environment.
      node_set = Nodes::NodeSet.new
      @nodes.linked_copy(node_set)
      context[:windows][:reboot].launch_on_node_set(node_set) do |ns|
        res = nil
        parallel_run(ns.id) do |pr|
          ns.set.each do |node|
            cmd = "#{context[:common].taktuk_connector} root@#{node.hostname} "\
              "\"mount | grep \\ \\/\\  | cut -f 1 -d\\ \""
            pr.add(cmd, node)
          end
          debug(3, 'A bunch of check prod env tests will be performed')
          pr.run
          pr.wait
          res = pr.get_results(
            { :output => context[:cluster].block_device + context[:cluster].prod_part }
          )
        end

        res[1].each do |node|
          set_node(node, :stderr => 'Bad root partition')
        end

        classify_nodes(res)
      end

      return (not @nodes_ok.empty?)
    end
  end

  # Load some specific drivers on the nodes
  #
  # Arguments
  # Output
  # * return true if the drivers have been successfully loaded, false otherwise
  def ms_load_drivers()
    cmd = String.new
    context[:cluster].drivers.each_index { |i|
      cmd += "modprobe #{context[:cluster].drivers[i]};"
    }
    return parallel_exec(cmd)
  end

  # Create the partition table on the nodes
  #
  # Arguments
  # Output
  # * return true if the operation has been successfully performed, false otherwise
  def ms_create_partition_table()
    return parallel_exec(
      run_script(),
      {
        :input_file => context[:cluster].partitioning_script,
        :scattering => :tree
      }
    )
  end

  # Perform the deployment part on the nodes
  #
  # Arguments
  # Output
  # * return true if the format has been successfully performed, false otherwise
  def ms_format_deploy_part()
    if context[:common].mkfs_options.has_key?(context[:execution].environment.filesystem) then
      opts = context[:common].mkfs_options[context[:execution].environment.filesystem]
      return parallel_exec(
        "mkdir -p #{context[:common].environment_extraction_dir}; "\
        "umount #{get_deploy_part_str()} 2>/dev/null; "\
        "mkfs -t #{context[:execution].environment.filesystem} #{opts} #{get_deploy_part_str()}"
      )
    else
      return parallel_exec(
        "mkdir -p #{context[:common].environment_extraction_dir}; "\
        "umount #{get_deploy_part_str()} 2>/dev/null; "\
        "mkfs -t #{context[:execution].environment.filesystem} #{get_deploy_part_str()}"
      )
    end
  end

  # Format the /tmp part on the nodes
  #
  # Arguments
  # Output
  # * return true if the format has been successfully performed, false otherwise
  def ms_format_tmp_part()
    fstype = context[:execution].reformat_tmp
    if context[:common].mkfs_options.has_key?(fstype) then
      opts = context[:common].mkfs_options[fstype]
      tmp_part = get_block_device_str() + context[:cluster].tmp_part
      return parallel_exec("mkdir -p /tmp; umount #{tmp_part} 2>/dev/null; mkfs.#{fstype} #{opts} #{tmp_part}")
    else
      tmp_part = get_block_device_str() + context[:cluster].tmp_part
      return parallel_exec("mkdir -p /tmp; umount #{tmp_part} 2>/dev/null; mkfs.#{fstype} #{tmp_part}")
    end
  end

  # Format the swap part on the nodes
  #
  # Arguments
  # Output
  # * return true if the format has been successfully performed, false otherwise
  def ms_format_swap_part()
    swap_part = get_block_device_str() + context[:cluster].swap_part
    return parallel_exec("mkswap #{swap_part}")
  end

  # Mount the deployment part on the nodes
  #
  # Arguments
  # Output
  # * return true if the mount has been successfully performed, false otherwise
  def ms_mount_deploy_part()
    return parallel_exec("mount #{get_deploy_part_str()} #{context[:common].environment_extraction_dir}")
  end

  # Mount the /tmp part on the nodes
  #
  # Arguments
  # Output
  # * return true if the mount has been successfully performed, false otherwise
  def ms_mount_tmp_part()
    tmp_part = get_block_device_str() + context[:cluster].tmp_part
    return parallel_exec("mount #{tmp_part} /tmp")
  end

  # Send the SSH key in the deployed environment
  #
  # Arguments
  # * scattering_kind:  kind of taktuk scatter (tree, chain)
  # Output
  # * return true if the keys have been successfully copied, false otherwise
  def ms_send_key(scattering_kind)
    dir = File.join(context[:common].environment_extraction_dir,'root','.ssh')
    return parallel_exec(
      "mkdir -p #{dir}; cat - >> #{File.join(dir,'authorized_keys')}"\
      "",
      {:input_file => context[:execution].key, :scattering => scattering_kind }
    )
  end

  # Wait some nodes after a reboot
  #
  # Arguments
  # * kind: the kind of reboot, "kexec" or "classical" (used to determine the configured timeouts)
  # * env: the environment that was booted, "deploy" for deployment env, "user" for deployed env (used to determine ports_up and ports_down)
  # * vlan: nodes have been set in a specific vlan (use vlan specific hostnames)
  # * timeout: override default timeout settings
  # * ports_up: up ports used to perform a reach test on the nodes
  # * ports_down: down ports used to perform a reach test on the nodes
  # Output
  # * return true if some nodes are here, false otherwise
  def ms_wait_reboot(kind='classical', env='deploy', vlan=false, timeout=nil, ports_up=nil, ports_down=nil)
    unless timeout
      if kind == 'kexec'
        timeout = context[:execution].timeout_reboot_kexec \
          || context[:cluster].timeout_reboot_kexec
      else
        timeout = context[:execution].timeout_reboot_classical \
          || context[:cluster].timeout_reboot_classical
      end
    end
    timeout = eval(timeout).to_i

    unless ports_up
      ports_up = [ context[:common].ssh_port ]
      ports_up << context[:common].test_deploy_env_port if env == 'deploy'
    end

    unless ports_down
      ports_down = []
      ports_down << context[:common].test_deploy_env_port if env == 'user'
    end

    init_nodes(
      :stdout => '',
      :stderr => 'Unreachable after the reboot',
      :state => 'KO',
      :node_state => 'reboot_in_progress'
    )

    start = Time.now.tv_sec
    sleep(context[:cluster].sleep_time_before_ping)

    while (((Time.now.tv_sec - start) < timeout) && (not @nodes.all_ok?))
      sleep(5)

      nodes_to_test = Nodes::NodeSet.new
      @nodes.set.each do |node|
        nodes_to_test.push(node) if node.state == 'KO'
      end

      context[:windows][:check].launch_on_node_set(nodes_to_test) do |ns|
        ns.set.each do |node|
          thr = Thread.new do
            nodeid = get_nodeid(node,vlan)

            if PortScanner.ping(nodeid, 1, context[:common].ssh_port) then
              unless PortScanner.ports_test(nodeid,ports_up,true)
                node.state = 'KO'
                next
              end

              unless PortScanner.ports_test(nodeid,ports_down,false)
                node.state = 'KO'
                next
              end

              set_node(
                node,
                :state => 'OK',
                :status => '0',
                :stderr => '',
                :node_state => 'rebooted'
              )
              @nodes_ok.push(node)

              debug(5,"#{node.hostname} is here after #{Time.now.tv_sec - start}s")
            end
          end
          @waitreboot_threads.add(thr)
        end

        #let's wait everybody
        @waitreboot_threads.list.each do |thr|
          thr.join
        end
        @waitreboot_threads = ThreadGroup.new
      end
      nodes_to_test = nil
    end

    @nodes.diff(@nodes_ok).linked_copy(@nodes_ko)
=begin
    res = [[],[]]
    @nodes.set.each do |node|
      if node.state == 'OK'
        res[0] << node
      else
        res[1] << node
      end
    end
    classify_nodes(res)
=end

    return (not @nodes_ok.empty?)
  end

  # Eventually install a bootloader
  #
  # Arguments
  # Output
  # * return true if case of success (the success should be tested better)
  def ms_install_bootloader()
    return parallel_exec(
      run_script(),
      { :input_file => context[:cluster].bootloader_script }
    )
  end

  def ms_sync()
    return parallel_exec("sync")
  end

  # Dummy method to put all the nodes in the node_ko set
  #
  # Arguments
  # Output
  # * return true (should be false sometimes :D)
  def ms_produce_bad_nodes()
    @nodes.linked_copy(@nodes_ko)
    return true
  end

  # Umount the deployment part on the nodes
  #
  # Arguments
  # Output
  # * return true if the deploy part has been successfully umounted, false otherwise
  def ms_umount_deploy_part()
    return parallel_exec("umount -l #{get_deploy_part_str()}")
  end

  # Send and uncompress the user environment on the nodes
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain, kastafior)
  # Output
  # * return true if the environment has been successfully uncompressed, false otherwise
  def ms_send_environment(scattering_kind)
    file = context[:execution].environment.image[:file]
    output_file = nil
    if context[:cluster].decompress_environment or context[:execution].environment.image[:shortkind] == 'fsa'
      output_file = get_tmp_file(file)
    end
    unless (decompress = get_decompress_cmd(
      context[:execution].environment.image[:shortkind],
      context[:common].environment_extraction_dir,
      get_deploy_part_str(),
      nil,
      output_file
    )) then
      failed_microstep("The #{tarball_kind} archive kind is not supported")
      return false
    end

    start = Time.now.to_i
    case scattering_kind
    when :bittorrent
      res = send_tarball_and_uncompress_with_bittorrent(file,decompress)
    when :chain
      res = send_tarball_and_uncompress_with_taktuk(:chain,file,decompress)
    when :tree
      res = send_tarball_and_uncompress_with_taktuk(:tree,file,decompress)
    when :kastafior
      res = send_tarball_and_uncompress_with_kastafior(file,decompress)
    when :kascade
      res = send_tarball_and_uncompress_with_kascade(file,decompress)
    when :custom
      res = send_tarball_and_uncompress_with_custom(
        context[:cluster].cmd_sendenv.dup,file,decompress)
    end
    debug(3, "Broadcast time: #{Time.now.to_i - start}s") if res
    return res
  end

  # Uncompress the user environment on the nodes
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain)
  # Output
  # * return true if the admin preinstall has been successfully uncompressed, false otherwise
  def ms_decompress_environment(scattering_kind)
    unless (decompress = get_decompress_cmd(
      context[:execution].environment.image[:shortkind],
      context[:common].environment_extraction_dir,
      get_deploy_part_str(),
      get_tmp_file(context[:execution].environment.image[:file])
    )) then
      failed_microstep("The #{tarball_kind} archive kind is not supported")
      return false
    end

    return parallel_exec(
      decompress,
      { :scattering => scattering_kind },
      { :status => ["0"] }
    )
  end


  # Send and execute the admin preinstalls on the nodes
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain)
  # Output
  # * return true if the admin preinstall has been successfully uncompressed, false otherwise
  def ms_manage_admin_pre_install(scattering_kind)
    #First we check if the preinstall has been defined in the environment
    if (context[:execution].environment.preinstall != nil) then
      preinstall = context[:execution].environment.preinstall

      unless (decompress = get_decompress_cmd(
        preinstall["kind"], context[:common].rambin_path)
      ) then
        failed_microstep("The #{tarball_kind} archive kind is not supported")
        return false
      end
      if not send_tarball_and_uncompress_with_taktuk(scattering_kind, preinstall["file"], decompress) then
        return false
      end
      if (preinstall["script"] != "none")
        if not parallel_exec("#{set_env()} #{context[:common].rambin_path}/#{preinstall["script"]}") then
          return false
        end
      end
      return true
    elsif (context[:cluster].admin_pre_install != nil) then
      context[:cluster].admin_pre_install.each do |preinst|
        unless (decompress = get_decompress_cmd(
          preinstall["kind"], context[:common].rambin_path)
        ) then
          failed_microstep("The #{tarball_kind} archive kind is not supported")
          return false
        end
        if not send_tarball_and_uncompress_with_taktuk(scattering_kind, preinst["file"], decompress) then
          return false
        end
        if (preinst["script"] != "none")
          if not parallel_exec("#{set_env()} #{context[:common].rambin_path}/#{preinst["script"]}") then
            return false
          end
        end
      end
      return true
    end
    return false
  end

  # Send and execute the admin postinstalls on the nodes
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain)
  # Output
  # * return true if the admin postinstall has been successfully uncompressed, false otherwise   
  def ms_manage_admin_post_install(scattering_kind)
    context[:cluster].admin_post_install.each do |postinstall|
      unless (decompress = get_decompress_cmd(
        postinstall["kind"], context[:common].rambin_path)
      ) then
        failed_microstep("The #{tarball_kind} archive kind is not supported")
        return false
      end
      if not send_tarball_and_uncompress_with_taktuk(scattering_kind, postinstall["file"], decompress) then
        return false
      end
      if (postinstall["script"] != "none")
        if not parallel_exec("#{set_env()} #{context[:common].rambin_path}/#{postinstall["script"]}") then
          return false
        end
      end
    end
    return true
  end

  # Send and execute the user postinstalls on the nodes
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain)
  # Output
  # * return true if the user postinstall has been successfully uncompressed, false otherwise
  def ms_manage_user_post_install(scattering_kind)
    context[:execution].environment.postinstall.each do |postinstall|
      unless (decompress = get_decompress_cmd(
        postinstall["kind"], context[:common].rambin_path)
      ) then
        failed_microstep("The #{tarball_kind} archive kind is not supported")
        return false
      end
      if not send_tarball_and_uncompress_with_taktuk(scattering_kind, postinstall["file"], decompress) then
        return false
      end
      if (postinstall["script"] != "none")
        if not parallel_exec("#{set_env()} #{context[:common].rambin_path}/#{postinstall["script"]}") then
          return false
        end
      end
    end
    return true
  end

  # Set a VLAN for the deployed nodes
  #
  # Arguments
  # Output
  # * return true if the operation has been correctly performed, false otherwise
  def ms_set_vlan(vlan_id=nil)
    list = String.new
    @nodes.make_array_of_hostname.each { |hostname| list += " -m #{hostname}" }

    vlan_id = context[:execution].vlan_id unless vlan_id
    cmd = context[:common].set_vlan_cmd.gsub("NODES", list).gsub("VLAN_ID", vlan_id).gsub("USER", context[:execution].user)

    unless command(cmd) then
      failed_microstep("Cannot set the VLAN")
      return false
    else
      return true
    end
  end
end

class CustomMicrostep < Microstep
  def initialize(nodes, context = {})
    output = context[:output]
    super('CUSTOM', 0, 0, nodes, 0, nil, output, context, [])
    @basenodes = Nodes::NodeSet.new
    nodes.linked_copy(@basenodes)
  end

  def method_missing(methname,*args)
    super(methname,*args) if methname.to_s =~ /^ms_/
    @name = methname
    @params = args

    @nodes_ok.clean()

    run()

    @nodes.clean
    @nodes_ok.linked_copy(@nodes)
  end
end

end
