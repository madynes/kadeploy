# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2012
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'debug'
require 'nodes'
require 'automata'
require 'parallel_ops'
require 'parallel_runner'
require 'pxe_ops'
require 'cache'
require 'bittorrent'
require 'process_management'

#Ruby libs
require 'ftools'
require 'socket'
require 'tempfile'

class Microstep < Automata::QueueTask
  attr_reader :output
  include Printer

  def initialize(name, idx, subidx, nodes, manager_queue, output, context = {}, params = [])
    super(name, idx, subidx, nodes, manager_queue, context, params)
    @output = output
    @runthread = nil
    @current_operation = nil
  end

  def run()
    ret = true

    @nodes_ok.set.each do |node|
      context[:config].set_node_state(
        node.hostname,
        context[:local][:parent].name.to_s,
        method_sym.to_s,
        "ok"
      )
    end

    ret = ret && run_custom_methods() if custom_methods_attached?

    if ret
      debug(3,"--- #{@name.to_s} (#{context[:cluster].name} cluster)")
      debug(3,"  >>> #{@nodes.to_s_fold}")

      start = Time.now.to_i
      ret = ret && send("ms_#{@name.to_s}".to_sym,*@params)
      debug(4,
        "  Time in #{context[:local][:parent].name.to_s}-#{@name.to_s}: "\
        "#{Time.now.to_i - start}s"
      )
    end

    if ret
      @nodes.linked_copy(@nodes_ok)
    else
      @nodes.linked_copy(@nodes_ko)
    end

puts "#### RET: #{@name.to_s}"
    ret
  end

  def kill
    # Be carefull to kill @runthread before killing @current_operation, in order to avoid the res condition: @runthread create the Operation object but do not set @current_operation because it was killed
    unless @runthread.nil?
      Thread.kill(@runthread)
      @runthread.join
    end
    @current_operation.kill unless @current_operation.nil?
  end

  private

  def failed_microstep(msg)
    debug(0, msg)
    @nodes_ok.set_error_msg(msg)
    @nodes_ok.duplicate_and_free(@nodes_ko)
    @nodes_ko.set.each { |n|
      n.state = "KO"
      context[:config].set_node_state(n.hostname, "", "", "ko")
    }
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
        debug(4, "The node #{n.hostname} has been discarded of the current instance")
        n.state = "KO"
        context[:config].set_node_state(n.hostname, "", "", "ko")
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

  def parallel_op(obj)
    raise '@current_operation should not be set' if @current_operation
    @current_operation = obj
    yield(obj)
    @current_operation = nil
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
    @nodes_ok.duplicate_and_free(node_set)

    do_exec = lambda do |nodeset|
      res = nil
      parallel_op(
        ParallelOperation.new(
          nodeset,
          context,
          @output
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
    node_set = Nodes::NodeSet.new
    @nodes_ok.duplicate_and_free(node_set)

    res = nil
    parallel_op(
      ParallelOperation.new(
        nodeset,
        context,
        @output
      )
    ) do |op|
      res = op.taktuk_sendfile(src_file,dest_dir,opts)
    end
    classify_nodes(res)

    return (not @nodes_ok.empty?)
  end

  def parallel_run(nodeset_id)
    raise unless block_given?
    parallel_op(ParallelRunner.new(@output,nodeset_id)) do |op|
      yield(op)
    end
  end

  # Wrap a parallel wait command
  #
  # Arguments
  # * timeout: time to wait
  # * ports_up: up ports probed on the rebooted nodes to test
  # * ports_down: down ports probed on the rebooted nodes to test
  # * nodes_check_window: instance of WindowManager
  # * last_reboot: specify if we wait the last reboot
  # Output
  # * return true if at least one node has been successfully rebooted, false otherwise
  def parallel_wait_nodes_after_reboot(timeout, ports_up, ports_down, nodes_check_window, vlan)
    node_set = Nodes::NodeSet.new
    @nodes_ok.duplicate_and_free(node_set)

    res = nil
    parallel_op(
      ParallelOperation.new(
        node_set,
        context,
        @output
      )
    ) do |op|
      res = op.wait_nodes_after_reboot(
        timeout, ports_up, ports_down, nodes_check_window, vlan
      )
    end
    classify_nodes(res)

    return (not @nodes_ok.empty?)
  end

  # Wrap a parallel command to get the power status
  #
  # Arguments
  # * instance_thread: thread id of the current thread
  # Output
  # * return true if the power status has been reached at least on one node, false otherwise
  def parallel_get_power_status()
    node_set = Nodes::NodeSet.new
    @nodes_ok.duplicate_and_free(node_set)
    debug(3, "  *** A power status will be performed on the nodes #{node_set.to_s_fold}")

    res = nil
    parallel_run(node_set.id) do |pr|
      node_set.set.each do |node|
        if (node.cmd.power_status != nil) then
          pr.add(node.cmd.power_status, node)
        else
          node.last_cmd_stderr = "power_status command is not provided"
          @nodes_ko.push(node)
        end
      end
      pr.run
      pr.wait
      res = pr.get_results
    end
    classify_nodes(res)
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
    debug(3, "  *** A #{level} #{kind} will be performed on the nodes #{node_set.to_s_fold}")

    #First, we remove the nodes without command
    no_command_provided_nodes = Nodes::NodeSet.new
    to_remove = Array.new
    node_set.set.each { |node|
      if (node.cmd.instance_variable_get("@#{kind}_#{level}") == nil) then
        node.last_cmd_stderr = "#{level}_#{kind} command is not provided"
        debug(3, "      /!\ No #{level} #{kind} command is defined for these nodes /!\ ")
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
              cmd = node.cmd.instance_variable_get("@#{kind}_#{level}")
            elsif entry.is_a?(Array) then
              node = initial_node_set.get_node_by_host(entry[0])
              cmd = replace_groups_in_command(node.cmd.instance_variable_get("@#{kind}_#{level}"), entry)
            else
              raise "Invalid entry in array"
            end
            #We directly transmit the --no-wait parameter to the power_on/power_off commands
            if (kind == "power_on") || (kind == "power_off") then
              
      cmd += " --no-wait" if (not context[:execution].wait)
            end
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
          node.last_cmd_exit_status = ref_node.last_cmd_exit_status
          node.last_cmd_stdout = ref_node.last_cmd_stdout
          node.last_cmd_stderr = ref_node.last_cmd_stderr
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
        return nil
      else
        return no_command_provided_nodes
      end
    else
      if no_command_provided_nodes.empty? then
        return bad_nodes
      else
        return no_command_provided_nodes.add(bad_nodes)
      end
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
    node_set = Nodes::NodeSet.new(@nodes_ok.id)
    initial_node_set = Nodes::NodeSet.new(@nodes_ok.id)
    @nodes_ok.move(node_set)
    node_set.linked_copy(initial_node_set)

    bad_nodes = Nodes::NodeSet.new
    map = Array.new
    map.push("soft")
    map.push("hard")
    map.push("very_hard")
    index = map.index(level)
    finished = false
      
    while ((index < map.length) && (not finished))
      bad_nodes = _escalation_cmd_wrapper(kind, map[index], node_set, initial_node_set)
      if (bad_nodes != nil) then
        node_set.delete
        index = index + 1
          if (index < map.length) then
            bad_nodes.move(node_set)
          else
            @nodes_ko.add(bad_nodes)
          end
      else
        finished = true
      end
    end
    map.clear
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
    file_array.each { |file|
      all_links_followed = false
      initial_file = file
      while (not all_links_followed) 
        prev_file = file
        case archive_kind
        when "tgz"
          cmd = "tar -C #{dest_dir} -xzf #{archive} #{file}"          
        when "tbz2"
          cmd = "tar -C #{dest_dir} -xjf #{archive} #{file}"
        else
          raise "The kind #{archive_kind} of archive is not supported"
        end
        if not system(cmd) then
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
        if not system("mv #{File.join(dest_dir,file)} #{File.join(dest_dir,dest)}") then
          failed_microstep("Cannot move the file #{File.join(dest_dir,file)} to #{File.join(dest_dir,dest)}")
          return false
        end
      end
    }
    return true
  end

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
    archive = context[:execution].environment.tarball["file"]
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
                                        context[:execution].environment.tarball["kind"],
                                        files_in_archive,
                                        tmpdir) then
        failed_microstep("Cannot extract the files from the archive")
        return false
      end
      files_in_archive.clear
      files.each { |file|
        src = File.join(tmpdir, File.basename(file))
        dst = File.join(dest_dir, context[:execution].prefix_in_cache + File.basename(file))
        if not system("mv #{src} #{dst}") then
          failed_microstep("Cannot move the file #{src} to #{dst}")
          return false
        end
      }
      if not system("rm -rf #{tmpdir}") then
        failed_microstep("Cannot remove the temporary directory #{tmpdir}")
        return false
      end
      return true
    else
      return true
    end
  end

  # Get the name of the deployment partition
  #
  # Arguments
  # * nothing
  # Output
  # * return the name of the deployment partition
  def get_deploy_part_str
    if (context[:execution].deploy_part != "") then
      if (context[:execution].block_device != "") then
        return context[:execution].block_device + context[:execution].deploy_part
      else
        return context[:cluster].block_device + context[:execution].deploy_part
      end
    else
      return context[:cluster].block_device + context[:cluster].deploy_part
    end
  end

  # Get the number of the deployment partition
  #
  # Arguments
  # * nothing
  # Output
  # * return the number of the deployment partition
  def get_deploy_part_num
    if (context[:execution].deploy_part != "") then
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
    kernel_params = String.new
    #We first check if the kernel parameters are defined in the environment
    if (context[:execution].environment.kernel_params != nil) then
      kernel_params = context[:execution].environment.kernel_params
    #Otherwise we eventually check in the cluster specific configuration
    elsif (context[:cluster].kernel_params != nil) then
      kernel_params = context[:cluster].kernel_params
    else
      kernel_params = ""
    end
    return kernel_params
  end

  # Install Grub-legacy on the deployment partition
  #
  # Arguments
  # * kind of OS (linux, xen)
  # Output
  # * return true if the installation of Grub-legacy has been successfully performed, false otherwise
  def install_grub1_on_nodes(kind)
    root = get_deploy_part_str()
    grubpart = "hd0,#{get_deploy_part_num() - 1}"
    path = context[:common].environment_extraction_dir
    line1 = line2 = line3 = ""
    kernel_params = get_kernel_params()
    case kind
    when "linux"
      line1 = "#{context[:execution].environment.kernel}"
      line1 += " #{kernel_params}" if kernel_params != ""
      if (context[:execution].environment.initrd == nil) then
        line2 = "none"
      else
        line2 = "#{context[:execution].environment.initrd}"
      end
    when "xen"
      line1 = "#{context[:execution].environment.hypervisor}"
      
      line1 += " #{context[:execution].environment.hypervisor_params}" if context[:execution].environment.hypervisor_params != nil
      line2 = "#{context[:execution].environment.kernel}"
      line2 += " #{kernel_params}" if kernel_params != ""
      if (context[:execution].environment.initrd == nil) then
        line3 = "none"
      else
        line3 = "#{context[:execution].environment.initrd}"
      end
    else
      failed_microstep("Invalid os kind #{kind}")
      return false
    end
    return parallel_exec(
      "(/usr/local/bin/install_grub "\
      "#{kind} #{root} \"#{grubpart}\" #{path} "\
      "\"#{line1}\" \"#{line2}\" \"#{line3}\")"
    )
  end

  # Install Grub 2 on the deployment partition
  #
  # Arguments
  # * kind of OS (linux, xen)
  # Output
  # * return true if the installation of Grub 2 has been successfully performed, false otherwise
  def install_grub2_on_nodes(kind)
    root = get_deploy_part_str()
    grubpart = "hd0,#{get_deploy_part_num()}"
    path = context[:common].environment_extraction_dir
    line1 = line2 = line3 = ""
    kernel_params = get_kernel_params()
    case kind
    when "linux"
      line1 = "#{context[:execution].environment.kernel}"
      line1 += " #{kernel_params}" if kernel_params != ""
      if (context[:execution].environment.initrd == nil) then
        line2 = "none"
      else
        line2 = "#{context[:execution].environment.initrd}"
      end
    when "xen"
      line1 = "#{context[:execution].environment.hypervisor}"
      line1 += " #{context[:execution].environment.hypervisor_params}" if context[:execution].environment.hypervisor_params != nil
      line2 = "#{context[:execution].environment.kernel}"
      line2 += " #{kernel_params}" if kernel_params != ""
      if (context[:execution].environment.initrd == nil) then
        line3 = "none"
      else
        line3 = "#{context[:execution].environment.initrd}"
      end
    else
      failed_microstep("Invalid os kind #{kind}")
      return false
    end
    return parallel_exec(
      "(/usr/local/bin/install_grub2 "\
      "#{kind} #{root} \"#{grubpart}\" #{path} "\
      "\"#{line1}\" \"#{line2}\" \"#{line3}\")",
      {},
      {:status => ["0"]}
    )
  end

  def install_grub_on_nodes(kind)
    case context[:common].grub
    when "grub1"
      return install_grub1_on_nodes(kind)
    when "grub2"
      return install_grub2_on_nodes(kind)
    else
      failed_microstep("#{context[:common].grub} is not a valid Grub choice")
      return false
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
  def send_tarball_and_uncompress_with_taktuk(scattering_kind, tarball_file, tarball_kind, deploy_mount_point, deploy_part)
    case tarball_kind
    when "tgz"
      cmd = "tar xz -C #{deploy_mount_point}"
    when "tbz2"
      cmd = "tar xj -C #{deploy_mount_point}"
    when "ddgz"
      cmd = "gzip -cd > #{deploy_part}"
    when "ddbz2"
      cmd = "bzip2 -cd > #{deploy_part}"
    else
      failed_microstep("The #{tarball_kind} archive kind is not supported")
      return false
    end
    return parallel_exec(
      cmd,
      { :input_file => tarball_file, :scattering => scattering_kind },
      { :status => ["0"] }
    )
  end

  # Send a tarball with Kastafior and uncompress it on the nodes
  #
  # Arguments
  # * tarball_file: path to the tarball
  # * tarball_kind: kind of archive (tgz, tbz2, ddgz, ddbz2)
  # * deploy_mount_point: deploy mount point
  # * deploy_mount_part: deploy mount part
  # Output
  # * return true if the operation is correctly performed, false otherwise
  def send_tarball_and_uncompress_with_kastafior(tarball_file, tarball_kind, deploy_mount_point, deploy_part)
    if context[:cluster].use_ip_to_deploy then
      node_set = Nodes::NodeSet.new
      @nodes_ok.duplicate_and_free(node_set)
      # Use a window not to flood ssh commands
      context[:windows][:reboot].launch_on_node_set(node_set) do |ns|
        res = nil
        parallel_run(ns.id) do |pr|
          ns.set.each do |node|
            kastafior_hostname = node.ip
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
    end

    nodefile = Tempfile.new("kastafior-nodefile")
    nodefile.puts(Socket.gethostname())
    if context[:cluster].use_ip_to_deploy then
      @nodes_ok.make_sorted_array_of_nodes.each { |node|
        nodefile.puts(node.ip)
      }
    else
      @nodes_ok.make_sorted_array_of_nodes.each { |node|
        nodefile.puts(node.hostname)
      }
    end
    nodefile.close
    case tarball_kind
    when "tgz"
      cmd = "tar xz -C #{deploy_mount_point}"
    when "tbz2"
      cmd = "tar xj -C #{deploy_mount_point}"
    when "ddgz"
      cmd = "gzip -cd > #{deploy_part}"
    when "ddbz2"
      cmd = "bzip2 -cd > #{deploy_part}"
    else
      failed_microstep("The #{tarball_kind} archive kind is not supported")
      return false
    end

    if context[:common].taktuk_auto_propagate then
      cmd = "#{context[:common].kastafior} -s -c \\\"#{context[:common].taktuk_connector}\\\"  -- -s \"cat #{tarball_file}\" -c \"#{cmd}\" -n #{nodefile.path} -f"
    else
      cmd = "#{context[:common].kastafior} -c \\\"#{context[:common].taktuk_connector}\\\" -- -s \"cat #{tarball_file}\" -c \"#{cmd}\" -n #{nodefile.path} -f"
    end
    exec = Execute[cmd]
    out = ''
    err = ''
    status = nil
    exec.run do |pid,stdin,stdout,stderr|
      Process.wait(pid)
      status = $?.exitstatus
      out = stdout.read(1000)
      stdout.close
      err = stderr.read(1000)
      stderr.close
    end

    @output.debug_command(cmd, out, err, status, @nodes_ok)
    if (status != 0) then
      failed_microstep("Error while processing to the file broadcast with Kastafior (exited with status #{status})")
      return false
    else
      return true
    end
  end

  # Send a tarball with Bittorrent and uncompress it on the nodes
  #
  # Arguments
  # * tarball_file: path to the tarball
  # * tarball_kind: kind of archive (tgz, tbz2, ddgz, ddbz2)
  # * deploy_mount_point: deploy mount point
  # * deploy_mount_part: deploy mount part
  # Output
  # * return true if the operation is correctly performed, false otherwise
  def send_tarball_and_uncompress_with_bittorrent(tarball_file, tarball_kind, deploy_mount_point, deploy_part)
    if not parallel_exec("rm -f /tmp/#{File.basename(tarball_file)}*") then
      failed_microstep("Error while cleaning the /tmp")
      return false
    end
    torrent = "#{tarball_file}.torrent"
    btdownload_state = "/tmp/btdownload_state#{Time.now.to_f}"
    tracker_pid, tracker_port = Bittorrent::launch_tracker(btdownload_state)
    if not Bittorrent::make_torrent(tarball_file, context[:common].bt_tracker_ip, tracker_port) then
      failed_microstep("The torrent file (#{torrent}) has not been created")
      return false
    end
    if context[:common].kadeploy_disable_cache then
      seed_pid = Bittorrent::launch_seed(torrent, File.dirname(tarball_file))
    else
      seed_pid = Bittorrent::launch_seed(torrent, context[:common].kadeploy_cache_dir)
    end
    if (seed_pid == -1) then
      failed_microstep("The seed of #{torrent} has not been launched")
      return false
    end
    if not parallel_sendfile(torrent, '/tmp', { :scattering => :tree }) then
      failed_microstep("Error while sending the torrent file")
      return false
    end
    if not parallel_exec("/usr/local/bin/bittorrent_detach /tmp/#{File.basename(torrent)}") then
      failed_microstep("Error while launching the bittorrent download")
      return false
    end
    sleep(20)
    expected_clients = @nodes_ok.length
    if not Bittorrent::wait_end_of_download(context[:common].bt_download_timeout, torrent, context[:common].bt_tracker_ip, tracker_port, expected_clients) then
      failed_microstep("A timeout for the bittorrent download has been reached")
      ProcessManagement::killall(seed_pid)
      return false
    end
    debug(3, "Shutdown the seed for #{torrent}")
    ProcessManagement::killall(seed_pid)
    debug(3, "Shutdown the tracker for #{torrent}")
    ProcessManagement::killall(tracker_pid)
    system("rm -f #{btdownload_state}")
    case tarball_kind
    when "tgz"
      cmd = "tar xzf /tmp/#{File.basename(tarball_file)} -C #{deploy_mount_point}"
    when "tbz2"
      cmd = "tar xjf /tmp/#{File.basename(tarball_file)} -C #{deploy_mount_point}"
    when "ddgz"
      cmd = "gzip -cd /tmp/#{File.basename(tarball_file)} > #{deploy_part}"
    when "ddbz2"
      cmd = "bzip2 -cd /tmp/#{File.basename(tarball_file)} > #{deploy_part}"
    else
      failed_microstep("The #{tarball_kind} archive kind is not supported")
      return false
    end
    if not parallel_exec(cmd) then
      failed_microstep("Error while uncompressing the tarball")
      return false
    end
    if not parallel_exec("rm -f /tmp/#{File.basename(tarball_file)}*") then
      failed_microstep("Error while cleaning the /tmp")
      return false
    end
    return true
  end

  # Execute a custom command on the nodes
  #
  # Arguments
  # * cmd: command to execute
  # Output
  # * return true if the command has been correctly performed, false otherwise
  def custom_exec_cmd(cmd)
    debug(3, "CUS exec_cmd: #{@nodes_ok.to_s_fold}")
    return parallel_exec(cmd)
  end

  # Send a custom file on the nodes
  #
  # Arguments
  # * file: filename
  # * dest_dir: destination directory on the nodes
  # Output
  # * return true if the file has been correctly sent, false otherwise
  def custom_send_file(file, dest_dir)
    debug(3, "CUS send_file: #{@nodes_ok.to_s_fold}")
    return parallel_sendfile(
      file,
      dest_dir,
      { :scattering => :chain}
    )
  end

  # Run the custom methods attached to a micro step
  #
  # Arguments
  # * macro_step: name of the macro step
  # * micro_step: name of the micro step
  # Output
  # * return true if the methods have been successfully executed, false otherwise    
  def run_custom_methods()
    result = true
    context[:execution].custom_operations[context[:local][:parent].name.to_s][@name.to_s].each { |entry|
      cmd = entry[0]
      arg = entry[1]
      dir = entry[2]
      case cmd
      when "exec"
        result = result && custom_exec_cmd(arg)
      when "send"
        result = result && custom_send_file(arg, dir)
      else
        failed_microstep("Invalid custom method: #{cmd}")
        return false
      end
    }
    return result
  end

  # Check if some custom methods are attached to a micro step
  #
  # Arguments
  # * macro_step: name of the macro step
  # * micro_step: name of the micro step
  # Output
  # * return true if at least one custom method is attached to the micro step, false otherwise
  def custom_methods_attached?()
    return ((context[:execution].custom_operations != nil) && 
            context[:execution].custom_operations.has_key?(context[:local][:parent].name.to_s) && 
            context[:execution].custom_operations[macro_step].has_key?(@name.to_s))
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

  # Create a string containing the environment variables for pre/post installs
  #
  # Arguments
  # * nothing
  # Output
  # * return the string containing the environment variables for pre/post installs
  def set_env
    env = String.new
    env = "KADEPLOY_CLUSTER=\"#{context[:cluster].name}\""
    env += " KADEPLOY_ENV=\"#{context[:execution].environment.name}\""
    env += " KADEPLOY_DEPLOY_PART=\"#{get_deploy_part_str()}\""
    env += " KADEPLOY_ENV_EXTRACTION_DIR=\"#{context[:common].environment_extraction_dir}\""
    env += " KADEPLOY_PREPOST_EXTRACTION_DIR=\"#{context[:common].rambin_path}\""
    return env
  end

  # Perform a fdisk on the nodes
  #
  # Arguments
  # * env: kind of environment on wich the fdisk operation is performed
  # Output
  # * return true if the fdisk has been successfully performed, false otherwise
  def do_fdisk(env)
    case env
    when "prod_env"
      expected_status = "256" #Strange thing, fdisk can not reload the partition table so it exits with 256
    when "untrusted_env"
      expected_status = "0"
    else
      failed_microstep("Invalid kind of deploy environment: #{env}")
      return false
    end
    begin
      temp = Tempfile.new("fdisk_#{context[:cluster].name}")
    rescue StandardError
      failed_microstep("Cannot create the tempfile fdisk_#{context[:cluster].name}")
      return false
    end
    if not system("cat #{context[:cluster].partition_file}|sed 's/PARTTYPE/#{context[:execution].environment.fdisk_type}/' > #{temp.path}") then
      failed_microstep("Cannot generate the partition_file")
      return false
    end
    if not parallel_exec(
      "fdisk #{context[:cluster].block_device}",
      { :input_file => temp.path, :scattering => :tree },
      { :status => expected_status}) then
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
    return parallel_exec(
      "cat - > /rambin/parted_script && chmod +x /rambin/parted_script && /rambin/parted_script",
      { :input_file => context[:cluster].partition_file, :scattering => :tree }
    )
  end

  public


  # Send the SSH key in the deployment environment
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain)
  # Output
  # * return true if the keys have been successfully copied, false otherwise
  def ms_send_key_in_deploy_env(scattering_kind)
    if (context[:execution].key != "") then
      cmd = "cat - >>/root/.ssh/authorized_keys"
      return parallel_exec(
        cmd,
        { :input_file => context[:execution].key, :scattering => scattering_kind}
      )
    else
      debug(3, "  *** No key has been specified")
    end
    return true
  end

  # Change the PXE configuration
  #
  # Arguments
  # * step: kind of change (prod_to_deploy_env, prod_to_nfsroot_env, chainload_pxe)
  # * pxe_profile_msg (opt): string containing the pxe profile
  # Output
  # * return true if the operation has been performed correctly, false otherwise
  def ms_switch_pxe(step, pxe_profile_msg = "")
    get_nodes = lambda { |check_vlan|
      @nodes_ok.set.collect { |node|
        if check_vlan && (context[:execution].vlan != nil) then 
          { 'hostname' => node.hostname, 'ip' => context[:execution].ip_in_vlan[node.hostname] }
        else
          { 'hostname' => node.hostname, 'ip' => node.ip }
        end
      }
    }

    case step
    when "prod_to_deploy_env"
      nodes = get_nodes.call(false)
      if not context[:common].pxe.set_pxe_for_linux(
          nodes,
          context[:cluster].deploy_kernel,
          context[:cluster].deploy_kernel_args,
          context[:cluster].deploy_initrd,
          "",
          context[:cluster].pxe_header) then
        failed_microstep("Cannot perform the set_pxe_for_linux operation")
        return false
      end
    when "prod_to_nfsroot_env"
      nodes = get_nodes.call(falpse)
      if not context[:common].pxe.set_pxe_for_nfsroot(
        nodes,
        context[:cluster].nfsroot_kernel,
        context[:cluster].nfsroot_params,
        context[:cluster].pxe_header) then
        failed_microstep("Cannot perform the set_pxe_for_nfsroot operation")
        return false
      end
    when "set_pxe"
      nodes = get_nodes.call(false)
      if not context[:common].pxe.set_pxe_for_custom(nodes,
                                                   pxe_profile_msg,
                                                   context[:execution].pxe_profile_singularities) then
        failed_microstep("Cannot perform the set_pxe_for_custom operation")
        return false
      end
    when "deploy_to_deployed_env"
      nodes = get_nodes.call(true)
      if (context[:execution].pxe_profile_msg != "") then
        if not context[:common].pxe.set_pxe_for_custom(nodes,
                                                     context[:execution].pxe_profile_msg,
                                                     context[:execution].pxe_profile_singularities) then
          failed_microstep("Cannot perform the set_pxe_for_custom operation")
          return false
        end
      else
        case context[:common].bootloader
        when "pure_pxe"
          case context[:execution].environment.environment_kind
          when "linux"
            kernel = context[:execution].prefix_in_cache + File.basename(context[:execution].environment.kernel)
            initrd = context[:execution].prefix_in_cache + File.basename(context[:execution].environment.initrd) if (context[:execution].environment.initrd != nil)
            images_dir = File.join(context[:common].pxe_repository, context[:common].pxe_repository_kernels)
            if not system("touch -a #{File.join(images_dir, kernel)}") then
              failed_microstep("Cannot touch #{File.join(images_dir, kernel)}")
              return false
            end
            if (context[:execution].environment.initrd != nil) then
              if not system("touch -a #{File.join(images_dir, initrd)}") then
                failed_microstep("Cannot touch #{File.join(images_dir, initrd)}")
                return false
              end
            end
            if not context[:common].pxe.set_pxe_for_linux(nodes,
              kernel,
              get_kernel_params(),
              initrd,
              get_deploy_part_str(),
              context[:cluster].pxe_header) then
              failed_microstep("Cannot perform the set_pxe_for_linux operation")
              return false
            end
          when "xen"
            kernel = context[:execution].prefix_in_cache + File.basename(context[:execution].environment.kernel)
            initrd = context[:execution].prefix_in_cache + File.basename(context[:execution].environment.initrd) if (context[:execution].environment.initrd != nil)
            hypervisor = context[:execution].prefix_in_cache + File.basename(context[:execution].environment.hypervisor)
            images_dir = File.join(context[:common].pxe_repository, context[:common].pxe_repository_kernels)
            if not system("touch -a #{File.join(images_dir, kernel)}") then
              failed_microstep("Cannot touch #{File.join(images_dir, kernel)}")
              return false
            end
            if (context[:execution].environment.initrd != nil) then
              if not system("touch -a #{File.join(images_dir, initrd)}") then
                failed_microstep("Cannot touch #{File.join(images_dir, initrd)}")
                return false
              end
            end
            if not system("touch -a #{File.join(images_dir, hypervisor)}") then
              failed_microstep("Cannot touch #{File.join(images_dir, hypervisor)}")
              return false
            end
            if not context[:common].pxe.set_pxe_for_xen(nodes,
                                                      hypervisor,
                                                      context[:execution].environment.hypervisor_params,
                                                      kernel,
                                                      get_kernel_params(),
                                                      initrd,
                                                      get_deploy_part_str(),
                                                      context[:cluster].pxe_header) then
              failed_microstep("Cannot perform the set_pxe_for_xen operation")
              return false
            end
          end
          Cache::clean_cache(File.join(context[:common].pxe_repository, context[:common].pxe_repository_kernels),
                             context[:common].pxe_repository_kernels_max_size * 1024 * 1024,
                             1,
                             /^(e\d+--.+)|(e-anon-.+)|(pxe-.+)$/,
                             @output)
        when "chainload_pxe"
          if (context[:execution].environment.environment_kind != "xen") then
            context[:common].pxe.set_pxe_for_chainload(nodes,
                                                     get_deploy_part_num(),
                                                     context[:cluster].pxe_header)
          else
            # debug(3, "Hack, Grub2 cannot boot a Xen Dom0, so let's use the pure PXE fashion")
            kernel = context[:execution].prefix_in_cache + File.basename(context[:execution].environment.kernel)
            initrd = context[:execution].prefix_in_cache + File.basename(context[:execution].environment.initrd) if (context[:execution].environment.initrd != nil)
            hypervisor = context[:execution].prefix_in_cache + File.basename(context[:execution].environment.hypervisor)
            images_dir = File.join(context[:common].pxe_repository, context[:common].pxe_repository_kernels)
            if not system("touch -a #{File.join(images_dir, kernel)}") then
              failed_microstep("Cannot touch #{File.join(images_dir, kernel)}")
              return false
            end
            if (context[:execution].environment.initrd != nil) then
              if not system("touch -a #{File.join(images_dir, initrd)}") then
                failed_microstep("Cannot touch #{File.join(images_dir, initrd)}")
                return false
              end
            end
            if not system("touch -a #{File.join(images_dir, hypervisor)}") then
              failed_microstep("Cannot touch #{File.join(images_dir, hypervisor)}")
              return false
            end
            if not context[:common].pxe.set_pxe_for_xen(nodes,
                                                      hypervisor,
                                                      context[:execution].environment.hypervisor_params,
                                                      kernel,
                                                      get_kernel_params(),
                                                      initrd,
                                                      get_deploy_part_str(),
                                                      context[:cluster].pxe_header) then
              failed_microstep("Cannot perform the set_pxe_for_xen operation")
              return false
            end
            Cache::clean_cache(File.join(context[:common].pxe_repository, context[:common].pxe_repository_kernels),
                               context[:common].pxe_repository_kernels_max_size * 1024 * 1024,
                               1,
                               /^(e\d+--.+)|(e-anon--.+)|(pxe-.+)$/,
                               @output)
          end
        end
      end
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
    first_attemp = (context[:local][:retries] == 0)
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
      script = "#!/bin/bash\n"
      script += shell_kexec(
        kernelfile,
        initrdfile,
        kernelparams,
        systemdir
      )

      tmpfile = Tempfile.new('kexec')
      tmpfile.write(script)
      tmpfile.close

      ret = parallel_exec(
        "file=`mktemp`;"\
        "cat - >$file;"\
        "chmod +x $file;"\
        "nohup $file 1>/dev/null 2>/dev/null </dev/null &",
        { :input_file => tmpfile.path, :scattering => :tree }
      )

      tmpfile.unlink

      return ret
    else
      debug(3, "   The Kexec optimization can only be used with a linux environment")
      return false
    end
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
      "--append=\"#{kernel_params}\" "\
    "&& sleep 1 "\
    "&& echo \"u\" > /proc/sysrq-trigger "\
    "&& nohup /sbin/kexec -e\n"
  end

  # Get the shell command used to follow a symbolic link until reaching the real file
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

  # Create kexec repository directory on current environment
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain, kastafior)
  # Output
  # * return true if the kernel has been successfully sent
  def ms_create_kexec_repository()
    return parallel_exec("mkdir -p #{context[:cluster].kexec_repository}")
  end

  # Send the deploy kernel files to an environment kexec repository
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain, kastafior)
  # Output
  # * return true if the kernel files have been sent successfully
  def ms_send_deployment_kernel(scattering_kind)
    ret = true

    pxedir = File.join(
      context[:common].pxe.pxe_repository,
      context[:common].pxe.pxe_repository_kernels
    )

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
    return parallel_exec("/usr/local/bin/reboot_detach", {},{}, context[:windows][:reboot])
  end

  # Perform a power operation on the current set of nodes_ok
  def ms_power(operation, level)
    case operation
    when "on"
      escalation_cmd_wrapper("power_on", level)
    when "off"
      escalation_cmd_wrapper("power_off", level)
    when "status"
      parallel_get_power_status()
    end
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
      @nodes_ok.duplicate_and_free(node_set)
      context[:windows][:reboot].launch_on_node_set(node_set) do |ns|
        res = nil
        parallel_run(ns.id) do |pr|
          ns.set.each do |node|
            cmd = "#{context[:common].taktuk_connector} root@#{node.hostname} "\
              "\"mount | grep \\ \\/\\  | cut -f 1 -d\\ \""
            pr.add(cmd, node)
          end
          debug(3, "  *** A bunch of check prod env tests will "\
            "be performed on #{ns.to_s_fold}")
          pr.run
          pr.wait
          res = pr.get_results(
            { :output => context[:cluster].block_device + context[:cluster].prod_part }
          )
        end

        res[1].each do |node|
          node.last_cmd_stderr = "Bad root partition"
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
  # * env: kind of environment on wich the patition creation is performed (prod_env or untrusted_env)
  # Output
  # * return true if the operation has been successfully performed, false otherwise
  def ms_create_partition_table(env)
    if context[:execution].disable_disk_partitioning then
      debug(3, "  *** Bypass the disk partitioning",@nodes_ok)
      return true
    else
      ret = true

      case context[:cluster].partition_creation_kind
      when "fdisk"
        ret = do_fdisk(env)
      when "parted"
        ret = do_parted()
      end

      ret = parallel_exec("partprobe #{context[:cluster].block_device}") if ret

      return ret
    end
  end

  # Perform the deployment part on the nodes
  #
  # Arguments
  # Output
  # * return true if the format has been successfully performed, false otherwise
  def ms_format_deploy_part()
    if ((context[:execution].environment.tarball["kind"] == "tgz") ||
        (context[:execution].environment.tarball["kind"] == "tbz2")) then
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
    else
      debug(3, "  *** Bypass the format of the deploy part")
      return true
    end
  end

  # Format the /tmp part on the nodes
  #
  # Arguments
  # Output
  # * return true if the format has been successfully performed, false otherwise
  def ms_format_tmp_part()
    if (context[:execution].reformat_tmp) then
      fstype = context[:execution].reformat_tmp_fstype
      if context[:common].mkfs_options.has_key?(fstype) then
        opts = context[:common].mkfs_options[fstype]
        tmp_part = context[:cluster].block_device + context[:cluster].tmp_part
        return parallel_exec("mkdir -p /tmp; umount #{tmp_part} 2>/dev/null; mkfs.#{fstype} #{opts} #{tmp_part}")
      else
        tmp_part = context[:cluster].block_device + context[:cluster].tmp_part
        return parallel_exec("mkdir -p /tmp; umount #{tmp_part} 2>/dev/null; mkfs.#{fstype} #{tmp_part}")
      end
    else
      debug(3, "  *** Bypass the format of the tmp part")
    end
    return true
  end

  # Format the swap part on the nodes
  #
  # Arguments
  # Output
  # * return true if the format has been successfully performed, false otherwise
  def ms_format_swap_part()
    if (context[:cluster].swap_part != nil) && (context[:cluster].swap_part!= "none") then
      swap_part = context[:cluster].block_device + context[:cluster].swap_part
      return parallel_exec("mkswap #{swap_part}")
    else
      debug(3, "  *** Bypass the format of the swap part")
    end
    return true
  end

  # Mount the deployment part on the nodes
  #
  # Arguments
  # Output
  # * return true if the mount has been successfully performed, false otherwise
  def ms_mount_deploy_part()
    #we do not mount the deploy part for a dd.gz or dd.bz2 image
    if ((context[:execution].environment.tarball["kind"] == "tgz") ||
        (context[:execution].environment.tarball["kind"] == "tbz2")) then
      return parallel_exec("mount #{get_deploy_part_str()} #{context[:common].environment_extraction_dir}")
    else
      debug(3, "  *** Bypass the mount of the deploy part")
      return true
    end
  end

  # Mount the /tmp part on the nodes
  #
  # Arguments
  # Output
  # * return true if the mount has been successfully performed, false otherwise
  def ms_mount_tmp_part()
    tmp_part = context[:cluster].block_device + context[:cluster].tmp_part
    return parallel_exec("mount #{tmp_part} /tmp")
  end

  # Send the SSH key in the deployed environment
  #
  # Arguments
  # * scattering_kind:  kind of taktuk scatter (tree, chain)
  # Output
  # * return true if the keys have been successfully copied, false otherwise
  def ms_send_key(scattering_kind)
    if ((context[:execution].key != "") && ((context[:execution].environment.tarball["kind"] == "tgz") ||
                                              (context[:execution].environment.tarball["kind"] == "tbz2"))) then
      cmd = "cat - >>#{context[:common].environment_extraction_dir}/root/.ssh/authorized_keys"
      return parallel_exec(
        cmd,
        {:input_file => context[:execution].key, :scattering => scattering_kind }
      )
    end
    return true
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
  def ms_wait_reboot(kind='classical', env='deploy', vlan=false, timeout=nil,ports_up=nil, ports_down=nil)
    unless timeout
      if kind == 'kexec'
        timeout = context[:execution].reboot_kexec_timeout \
          || context[:cluster].timeout_reboot_kexec
      else
        timeout = context[:execution].reboot_classical_timeout \
          || context[:cluster].timeout_reboot_classical
      end
    end

    unless ports_up
      ports_up = [ context[:common].ssh_port ]
      if env == 'deploy'
        ports_up << context[:common].test_deploy_env_port
      end
    end

    unless ports_down
      ports_down = []
      if env == 'user'
        ports_down << context[:common].test_deploy_env_port
      end
    end

    return parallel_wait_nodes_after_reboot(
      timeout,
      ports_up,
      ports_down,
      context[:windows][:check],
      vlan
    )
  end

  # Eventually install a bootloader
  #
  # Arguments
  # Output
  # * return true if case of success (the success should be tested better)
  def ms_install_bootloader()
    case context[:common].bootloader
    when "pure_pxe"
      case context[:execution].environment.environment_kind
      when "linux"
        return copy_kernel_initrd_to_pxe([context[:execution].environment.kernel,
                                          context[:execution].environment.initrd])
      when "xen"
        return copy_kernel_initrd_to_pxe([context[:execution].environment.kernel,
                                          context[:execution].environment.initrd,
                                          context[:execution].environment.hypervisor])
      when "other"
        failed_microstep("Only linux and xen environments can be booted with a pure PXE configuration")
        return false
      end
    when "chainload_pxe"
      if context[:execution].disable_bootloader_install then
        debug(3, "  *** Bypass the bootloader installation")
        return true
      else
        case context[:execution].environment.environment_kind
        when "linux"
          return install_grub_on_nodes("linux")
        when "xen"
#            return install_grub_on_nodes("xen")
          debug(3, "   Hack, Grub2 cannot boot a Xen Dom0, so let's use the pure PXE fashion")
          return copy_kernel_initrd_to_pxe([context[:execution].environment.kernel,
                                            context[:execution].environment.initrd,
                                            context[:execution].environment.hypervisor])

        when "other"
          #in this case, the bootloader must be installed by the user (dd partition)
          return true
        end
      end
    else
      failed_microstep("Invalid bootloader value: #{context[:common].bootloader}")
      return false
    end
  end

  # Dummy method to put all the nodes in the node_ko set
  #
  # Arguments
  # Output
  # * return true (should be false sometimes :D)
  def ms_produce_bad_nodes()
    @nodes_ok.duplicate_and_free(@nodes_ko)
    return true
  end

  # Umount the deployment part on the nodes
  #
  # Arguments
  # Output
  # * return true if the deploy part has been successfully umounted, false otherwise
  def ms_umount_deploy_part()
    if ((context[:execution].environment.tarball["kind"] == "tgz") ||
        (context[:execution].environment.tarball["kind"] == "tbz2")) then
      return parallel_exec("umount -l #{get_deploy_part_str()}")
    else
      debug(3, "  *** Bypass the umount of the deploy part")
      return true
    end
  end

  # Send and uncompress the user environment on the nodes
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain, kastafior)
  # Output
  # * return true if the environment has been successfully uncompressed, false otherwise
  def ms_send_environment(scattering_kind)
    start = Time.now.to_i
    case scattering_kind
    when :bittorrent
      res = send_tarball_and_uncompress_with_bittorrent(
        context[:execution].environment.tarball["file"],
        context[:execution].environment.tarball["kind"],
        context[:common].environment_extraction_dir,
        get_deploy_part_str()
      )
    when :chain
      res = send_tarball_and_uncompress_with_taktuk(
        :chain,
        context[:execution].environment.tarball["file"],
        context[:execution].environment.tarball["kind"],
        context[:common].environment_extraction_dir,
        get_deploy_part_str()
      )
    when :tree
      res = send_tarball_and_uncompress_with_taktuk(
        :tree,
        context[:execution].environment.tarball["file"],
        context[:execution].environment.tarball["kind"],
        context[:common].environment_extraction_dir,
        get_deploy_part_str()
      )
    when :kastafior
      res = send_tarball_and_uncompress_with_kastafior(
       context[:execution].environment.tarball["file"],
       context[:execution].environment.tarball["kind"],
       context[:common].environment_extraction_dir,
       get_deploy_part_str()
      )
    end
    debug(3, "  *** Broadcast time: #{Time.now.to_i - start} seconds") if res
    return res
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
      if not send_tarball_and_uncompress_with_taktuk(scattering_kind, preinstall["file"], preinstall["kind"], context[:common].rambin_path, "") then
        return false
      end
      if (preinstall["script"] != "none")
        if not parallel_exec("(#{set_env()} #{context[:common].rambin_path}/#{preinstall["script"]})") then
          return false
        end
      end
    elsif (context[:cluster].admin_pre_install != nil) then
      context[:cluster].admin_pre_install.each { |preinstall|
        if not send_tarball_and_uncompress_with_taktuk(scattering_kind, preinstall["file"], preinstall["kind"], context[:common].rambin_path, "") then
          return false
        end
        if (preinstall["script"] != "none")
          if not parallel_exec("(#{set_env()} #{context[:common].rambin_path}/#{preinstall["script"]})") then
            return false
          end
        end
      }
    else
      debug(3, "  *** Bypass the admin preinstalls")
    end
    return true
  end

  # Send and execute the admin postinstalls on the nodes
  #
  # Arguments
  # * scattering_kind: kind of taktuk scatter (tree, chain)
  # Output
  # * return true if the admin postinstall has been successfully uncompressed, false otherwise   
  def ms_manage_admin_post_install(scattering_kind)
    if (context[:execution].environment.environment_kind != "other") && (context[:cluster].admin_post_install != nil) then
      context[:cluster].admin_post_install.each { |postinstall|
        if not send_tarball_and_uncompress_with_taktuk(scattering_kind, postinstall["file"], postinstall["kind"], context[:common].rambin_path, "") then
          return false
        end
        if (postinstall["script"] != "none")
          if not parallel_exec("(#{set_env()} #{context[:common].rambin_path}/#{postinstall["script"]})") then
            return false
          end
        end
      }
    else
      debug(3, "  *** Bypass the admin postinstalls")
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
    if (context[:execution].environment.environment_kind != "other") && (context[:execution].environment.postinstall != nil) then
      context[:execution].environment.postinstall.each { |postinstall|
        if not send_tarball_and_uncompress_with_taktuk(scattering_kind, postinstall["file"], postinstall["kind"], context[:common].rambin_path, "") then
          return false
        end
        if (postinstall["script"] != "none")
          if not parallel_exec("(#{set_env()} #{context[:common].rambin_path}/#{postinstall["script"]})") then
            return false
          end
        end
      }
    else
      debug(3, "  *** Bypass the user postinstalls")
    end
    return true
  end

  # Set a VLAN for the deployed nodes
  #
  # Arguments
  # Output
  # * return true if the operation has been correctly performed, false otherwise
  def ms_set_vlan(vlan_id=nil)
    if (context[:execution].vlan != nil) then
      list = String.new
      @nodes_ok.make_array_of_hostname.each { |hostname|
        list += " -m #{hostname}"
      }
      vlan_id = context[:execution].vlan unless vlan_id
      cmd = context[:common].set_vlan_cmd.gsub("NODES", list).gsub("VLAN_ID", vlan_id).gsub("USER", context[:execution].true_user)
      if (not system(cmd)) then
        failed_microstep("Cannot set the VLAN")
        return false
      end
    else
      debug(3, "  *** Bypass the VLAN setting")
    end
    return true
  end
end
