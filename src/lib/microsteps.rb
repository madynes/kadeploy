# -*- coding: undecided -*-
# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'debug'
require 'nodes'
require 'parallel_ops'
require 'parallel_runner'
require 'pxe_ops'
require 'cache'
require 'bittorrent'
require 'process_management'

#Ruby libs
require 'ftools'
require 'socket'

module MicroStepsLibrary
  class MicroSteps
    attr_accessor :nodes_ok
    attr_accessor :nodes_ko
    @reboot_window = nil
    @config = nil
    @cluster = nil
    @output = nil
    @macro_step = nil
    attr_reader :process_container

    # Constructor of MicroSteps
    #
    # Arguments
    # * nodes_ok: NodeSet of nodes OK
    # * nodes_ko: NodeSet of nodes KO
    # * reboot_window: WindowManager instance
    # * nodes_check_window: WindowManager instance
    # * config: instance of Config
    # * cluster: cluster name of the nodes
    # * output: OutputControl instance
    # * macro_step: name of the current MacroStep instance
    # Output
    # * nothing
    def initialize(nodes_ok, nodes_ko, reboot_window, nodes_check_window, config, cluster, output, macro_step)
      @nodes_ok = nodes_ok
      @nodes_ko = nodes_ko
      @reboot_window = reboot_window
      @nodes_check_window = nodes_check_window
      @config = config
      @cluster = cluster
      @output = output
      @macro_step = macro_step
      @process_container = ProcessManagement::Container.new
    end

    private

    def failed_microstep(msg)
      @output.verbosel(0, msg)
      @nodes_ok.set_error_msg(msg)
      @nodes_ok.duplicate_and_free(@nodes_ko)
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
          @output.verbosel(4, "The node #{n.hostname} has been discarded of the current instance")
          @config.set_node_state(n.hostname, "", "", "ko")
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

    # Wrap a parallel command
    #
    # Arguments
    # * cmd: command to execute on nodes_ok
    # * taktuk_connector: specifies the connector to use with Taktuk
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the command has been successfully ran on one node at least, false otherwise
    def parallel_exec_command_wrapper(cmd, taktuk_connector, instance_thread)
      node_set = Nodes::NodeSet.new
      @nodes_ok.duplicate_and_free(node_set)
      po = ParallelOperations::ParallelOps.new(node_set, @config, @cluster, taktuk_connector, @output, instance_thread, @process_container)
      classify_nodes(po.execute(cmd))
      return (not @nodes_ok.empty?)
    end

    # Wrap a parallel command and expects a given set of exit status
    #
    # Arguments
    # * cmd: command to execute on nodes_ok
    # * status: array of exit status expected
    # * taktuk_connector: specifies the connector to use with Taktuk
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the command has been successfully ran on one node at least, false otherwise
    def parallel_exec_command_wrapper_expecting_status(cmd, status, taktuk_connector, instance_thread)
      node_set = Nodes::NodeSet.new
      @nodes_ok.duplicate_and_free(node_set)
      po = ParallelOperations::ParallelOps.new(node_set, @config, @cluster, taktuk_connector, @output, instance_thread, @process_container)
      classify_nodes(po.execute_expecting_status(cmd, status))
      return (not @nodes_ok.empty?)
    end 
  
    # Wrap a parallel command and expects a given set of exit status and an output
    #
    # Arguments
    # * cmd: command to execute on nodes_ok
    # * status: array of exit status expected
    # * output: string that contains the output expected
    # * taktuk_connector: specifies the connector to use with Taktuk
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the command has been successfully ran on one node at least, false otherwise
    def parallel_exec_command_wrapper_expecting_status_and_output(cmd, status, output, taktuk_connector, instance_thread)
      node_set = Nodes::NodeSet.new
      @nodes_ok.duplicate_and_free(node_set)
      po = ParallelOperations::ParallelOps.new(node_set, @config, @cluster, taktuk_connector, @output, instance_thread, @process_container)
      classify_nodes(po.execute_expecting_status_and_output(cmd, status, output))
      return (not @nodes_ok.empty?)
    end

    # Wrap a parallel send of file
    #
    # Arguments
    # * file: file to send
    # * dest_dir: destination of the file on the nodes
    # * scattering_kind: kind of taktuk scatter (tree, chain)
    # * taktuk_connector: specifies the connector to use with Taktuk
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the file has been successfully sent on one node at least, false otherwise
    def parallel_send_file_command_wrapper(file, dest_dir, scattering_kind, taktuk_connector, instance_thread)
      node_set = Nodes::NodeSet.new
      @nodes_ok.duplicate_and_free(node_set)
      po = ParallelOperations::ParallelOps.new(node_set, @config, @cluster, taktuk_connector, @output, instance_thread, @process_container)
      classify_nodes(po.send_file(file, dest_dir, scattering_kind))
      return (not @nodes_ok.empty?)
    end

    # Wrap a parallel command that uses an input file
    #
    # Arguments
    # * file: file to send as input
    # * cmd: command to execute on nodes_ok
    # * taktuk_connector: specifies the connector to use with Taktuk
    # * scattering_kind: kind of taktuk scatter (tree, chain)
    # * taktuk_connector: specifies the connector to use with Taktuk
    # * status: array of exit status expected
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the command has been successfully ran on one node at least, false otherwise
    def parallel_exec_cmd_with_input_file_wrapper(file, cmd, scattering_kind, taktuk_connector, status, instance_thread)
      node_set = Nodes::NodeSet.new
      @nodes_ok.duplicate_and_free(node_set)
      po = ParallelOperations::ParallelOps.new(node_set, @config, @cluster, taktuk_connector, @output, instance_thread, @process_container)
      classify_nodes(po.exec_cmd_with_input_file(file, cmd, scattering_kind, status))
      return (not @nodes_ok.empty?)
    end

    # Wrap a parallel wait command
    #
    # Arguments
    # * timeout: time to wait
    # * ports_up: up ports probed on the rebooted nodes to test
    # * ports_down: down ports probed on the rebooted nodes to test
    # * nodes_check_window: instance of WindowManager
    # * instance_thread: thread id of the current thread
    # * last_reboot: specify if we wait the last reboot
    # Output
    # * return true if at least one node has been successfully rebooted, false otherwise
    def parallel_wait_nodes_after_reboot_wrapper(timeout, ports_up, ports_down, nodes_check_window, instance_thread, last_reboot)
      node_set = Nodes::NodeSet.new
      @nodes_ok.duplicate_and_free(node_set)
      po = ParallelOperations::ParallelOps.new(node_set, @config, @cluster, nil, @output, instance_thread, @process_container)
      classify_nodes(po.wait_nodes_after_reboot(timeout, ports_up, ports_down, nodes_check_window, last_reboot))
      return (not @nodes_ok.empty?)
    end

    # Wrap a parallel command to get the power status
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the power status has been reached at least on one node, false otherwise
    def parallel_get_power_status(instance_thread)
      node_set = Nodes::NodeSet.new
      @nodes_ok.duplicate_and_free(node_set)
      @output.verbosel(3, "  *** A power status will be performed on the nodes #{node_set.to_s_fold}")
      pr = ParallelRunner::PRunner.new(@output, instance_thread, @process_container)
      node_set.set.each { |node|
        if (node.cmd.power_status != nil) then
          pr.add(node.cmd.power_status, node)
        else
          node.last_cmd_stderr = "power_status command is not provided"
          @nodes_ko.push(node)
        end
      }
      pr.run
      pr.wait
      classify_nodes(pr.get_results)
      return (not @nodes_ok.empty?)
    end

    # For history ...
    #
    # # Sub function for ecalation_cmd_wrapper
    # #
    # # Arguments
    # # * kind: kind of command to perform (reboot, power_on, power_off)
    # # * level: start level of the command (soft, hard, very_hard)
    # # * ns: NodeSet
    # # * instance_thread: thread id of the current thread
    # # Output
    # # * nothing
    # def _escalation_cmd_wrapper(kind, level, ns, instance_thread)
    #   node_set = Nodes::NodeSet.new
    #   ns.duplicate(node_set)
    #   @output.verbosel(3, "  *** A #{level} #{kind} will be performed on the nodes #{node_set.to_s_fold}")
    #   pr = ParallelRunner::PRunner.new(@output, instance_thread, @process_container)
    #   no_command_provided_nodes = Nodes::NodeSet.new
    #   node_set.set.each { |node|
    #     cmd = node.cmd.instance_variable_get("@#{kind}_#{level}")
    #     if (cmd != nil) then
    #       pr.add(cmd, node)
    #     else
    #       node.last_cmd_stderr = "#{kind}_#{level} command is not provided"
    #       no_command_provided_nodes.push(node)
    #     end
    #   }
    #   pr.run
    #   pr.wait
    #   bad_nodes = classify_only_good_nodes(pr.get_results)
    #   if bad_nodes == nil then
    #     if no_command_provided_nodes.empty? then
    #       return nil
    #     else
    #       return no_command_provided_nodes
    #     end
    #   else
    #     if no_command_provided_nodes.empty? then
    #       return bad_nodes
    #     else
    #       return no_command_provided_nodes.add(bad_nodes)
    #     end
    #   end
    # end
    
    # # Wrap an escalation command
    # #
    # # Arguments
    # # * kind: kind of command to perform (reboot, power_on, power_off)
    # # * level: start level of the command (soft, hard, very_hard)
    # # * instance_thread: thread id of the current thread
    # # Output
    # # * nothing 
    # def escalation_cmd_wrapper(kind, level, instance_thread)
    #   node_set = Nodes::NodeSet.new
    #   initial_node_set = Nodes::NodeSet.new
    #   @nodes_ok.duplicate(initial_node_set)
    #   @nodes_ok.duplicate_and_free(node_set)
    #   callback = Proc.new { |ns|
    #     bad_nodes = Nodes::NodeSet.new
    #     map = Array.new
    #     map.push("soft")
    #     map.push("hard")
    #     map.push("very_hard")
    #     index = map.index(level)
    #     finished = false
        
    #     while ((index < map.length) && (not finished))
    #       bad_nodes = _escalation_cmd_wrapper(kind, map[index], ns, instance_thread)
    #       if (bad_nodes != nil) then
    #         ns.free
    #         index = index + 1
    #         if (index < map.length) then
    #           bad_nodes.duplicate_and_free(ns)
    #         else
    #           @nodes_ko.add(bad_nodes)
    #         end
    #       else
    #         finished = true
    #       end
    #     end
    #     map.clear
    #   }
    #   @reboot_window.launch(node_set, &callback)
    #   if @nodes_ok.empty? then
    #     @nodes_ko.add(node_set)
    #   end
    #   node_set = nil
    #   initial_node_set.free
    #   initial_node_set = nil
    # end


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
    # * instance_thread: thread id of the current thread
    # Output
    # * nothing
    def _escalation_cmd_wrapper(kind, level, node_set, initial_node_set, instance_thread)
      @output.verbosel(3, "  *** A #{level} #{kind} will be performed on the nodes #{node_set.to_s_fold}")

      #First, we remove the nodes without command
      no_command_provided_nodes = Nodes::NodeSet.new
      to_remove = Array.new
      node_set.set.each { |node|
        if (node.cmd.instance_variable_get("@#{kind}_#{level}") == nil) then
          node.last_cmd_stderr = "#{level}_#{kind} command is not provided"
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
      if @config.cluster_specific[@cluster].group_of_nodes.has_key?("#{level}_#{kind}") then
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
              @config.cluster_specific[@cluster].group_of_nodes["#{level}_#{kind}"].each { |group|
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
                @output.verbosel(3, "The #{level} #{kind} command cannot be performed since the node #{node.hostname} belongs to the following group of nodes [#{dependency_group.join(",")}] and all the nodes of the group are not in involved in the command")
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
      callback = Proc.new { |na|
        pr = ParallelRunner::PRunner.new(@output, instance_thread, @process_container)
        na.each { |entry|
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
            cmd += " --no-wait" if (not @config.exec_specific.wait)
          end
          pr.add(cmd, node)
        }
        pr.run
        pr.wait
        res = classify_only_good_nodes(pr.get_results)
        bad_nodes.add(res) if res != nil
      }
      @reboot_window.launch_on_node_array(final_node_array, &callback) if not final_node_array.empty?

      #We eventually copy the status of grouped nodes
      backup_of_final_node_array.each { |entry|
        if entry.is_a?(Array) then
          ref_node = initial_node_set.get_node_by_host(entry[0])
          (1...(entry.length)).each { |index|
            node = initial_node_set.get_node_by_host(entry[index])
            node.last_cmd_exit_status = ref_node.last_cmd_exit_status
            node.last_cmd_stdout = ref_node.last_cmd_stdout
            node.last_cmd_stderr = ref_node.last_cmd_stderr
            if (ref_node.last_cmd_exit_status == "0") then
              @nodes_ok.push(node)
            else
              bad_nodes.push(node)
            end
          }
        end
      }

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
    # * instance_thread: thread id of the current thread
    # Output
    # * nothing 
    def escalation_cmd_wrapper(kind, level, instance_thread)
      node_set = Nodes::NodeSet.new
      initial_node_set = Nodes::NodeSet.new
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
        bad_nodes = _escalation_cmd_wrapper(kind, map[index], node_set, initial_node_set, instance_thread)
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
      archive = @config.exec_specific.environment.tarball["file"]
      dest_dir = File.join(@config.common.tftp_repository, @config.common.tftp_images_path)
      files.each { |file|
        if not (File.exist?(File.join(dest_dir, @config.exec_specific.prefix_in_cache + File.basename(file)))) then
          must_extract = true
        end
      }
      if not must_extract then
        files.each { |file|
          #If the archive has been modified, re-extraction required
          if (File.mtime(archive).to_i > File.atime(File.join(dest_dir, @config.exec_specific.prefix_in_cache + File.basename(file))).to_i) then
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
                                          @config.exec_specific.environment.tarball["kind"],
                                          files_in_archive,
                                          tmpdir) then
          failed_microstep("Cannot extract the files from the archive")
          return false
        end
        files_in_archive.clear
        files.each { |file|
          src = File.join(tmpdir, File.basename(file))
          dst = File.join(dest_dir, @config.exec_specific.prefix_in_cache + File.basename(file))
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
      if (@config.exec_specific.deploy_part != "") then
        if (@config.exec_specific.block_device != "") then
          return @config.exec_specific.block_device + @config.exec_specific.deploy_part
        else
          return @config.cluster_specific[@cluster].block_device + @config.exec_specific.deploy_part
        end
      else
        return @config.cluster_specific[@cluster].block_device + @config.cluster_specific[@cluster].deploy_part
      end
    end

    # Get the number of the deployment partition
    #
    # Arguments
    # * nothing
    # Output
    # * return the number of the deployment partition
    def get_deploy_part_num
      if (@config.exec_specific.deploy_part != "") then
        return @config.exec_specific.deploy_part.to_i
      else
        return @config.cluster_specific[@cluster].deploy_part.to_i
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
      if (@config.exec_specific.environment.kernel_params != nil) then
        kernel_params = @config.exec_specific.environment.kernel_params
      #Otherwise we eventually check in the cluster specific configuration
      elsif (@config.cluster_specific[@cluster].kernel_params != nil) then
        kernel_params = @config.cluster_specific[@cluster].kernel_params
      else
        kernel_params = ""
      end
      return kernel_params
    end

    # Install Grub-legacy on the deployment partition
    #
    # Arguments
    # * kind of OS (linux, xen)
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the installation of Grub-legacy has been successfully performed, false otherwise
    def install_grub1_on_nodes(kind, instance_thread)
      root = get_deploy_part_str()
      grubpart = "hd0,#{get_deploy_part_num() - 1}"
      path = @config.common.environment_extraction_dir
      line1 = line2 = line3 = ""
      kernel_params = get_kernel_params()
      case kind
      when "linux"
        line1 = "#{@config.exec_specific.environment.kernel}"
        line1 += " #{kernel_params}" if kernel_params != ""
        if (@config.exec_specific.environment.initrd == nil) then
          line2 = "none"
        else
          line2 = "#{@config.exec_specific.environment.initrd}"
        end
      when "xen"
        line1 = "#{@config.exec_specific.environment.hypervisor}"
        line1 += " #{@config.exec_specific.environment.hypervisor_params}" if @config.exec_specific.environment.hypervisor_params != nil
        line2 = "#{@config.exec_specific.environment.kernel}"
        line2 += " #{kernel_params}" if kernel_params != ""
        if (@config.exec_specific.environment.initrd == nil) then
          line3 = "none"
        else
          line3 = "#{@config.exec_specific.environment.initrd}"
        end
      else
        failed_microstep("Invalid os kind #{kind}")
        return false
      end
      return parallel_exec_command_wrapper_expecting_status("(/usr/local/bin/install_grub \
                                                            #{kind} #{root} \"#{grubpart}\" #{path} \
                                                            \"#{line1}\" \"#{line2}\" \"#{line3}\")",
                                                            ["0"],
                                                            @config.common.taktuk_connector,
                                                            instance_thread)
    end

    # Install Grub 2 on the deployment partition
    #
    # Arguments
    # * kind of OS (linux, xen)
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the installation of Grub 2 has been successfully performed, false otherwise
    def install_grub2_on_nodes(kind, instance_thread)
      root = get_deploy_part_str()
      grubpart = "hd0,#{get_deploy_part_num()}"
      path = @config.common.environment_extraction_dir
      line1 = line2 = line3 = ""
      kernel_params = get_kernel_params()
      case kind
      when "linux"
        line1 = "#{@config.exec_specific.environment.kernel}"
        line1 += " #{kernel_params}" if kernel_params != ""
        if (@config.exec_specific.environment.initrd == nil) then
          line2 = "none"
        else
          line2 = "#{@config.exec_specific.environment.initrd}"
        end
      when "xen"
        line1 = "#{@config.exec_specific.environment.hypervisor}"
        line1 += " #{@config.exec_specific.environment.hypervisor_params}" if @config.exec_specific.environment.hypervisor_params != nil
        line2 = "#{@config.exec_specific.environment.kernel}"
        line2 += " #{kernel_params}" if kernel_params != ""
        if (@config.exec_specific.environment.initrd == nil) then
          line3 = "none"
        else
          line3 = "#{@config.exec_specific.environment.initrd}"
        end
      else
        failed_microstep("Invalid os kind #{kind}")
        return false
      end
      return parallel_exec_command_wrapper_expecting_status("(/usr/local/bin/install_grub2 \
                                                            #{kind} #{root} \"#{grubpart}\" #{path} \
                                                            \"#{line1}\" \"#{line2}\" \"#{line3}\")",
                                                            ["0"],
                                                            @config.common.taktuk_connector,
                                                            instance_thread)
    end


    # Send a tarball with Taktuk and uncompress it on the nodes
    #
    # Arguments
    # * scattering_kind:  kind of taktuk scatter (tree, chain)
    # * tarball_file: path to the tarball
    # * tarball_kind: kind of archive (tgz, tbz2, ddgz, ddbz2)
    # * deploy_mount_point: deploy mount point
    # * deploy_mount_part: deploy mount part
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the operation is correctly performed, false otherwise
    def send_tarball_and_uncompress_with_taktuk(scattering_kind, tarball_file, tarball_kind, deploy_mount_point, deploy_part, instance_thread)
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
      return parallel_exec_cmd_with_input_file_wrapper(tarball_file,
                                                       cmd,
                                                       scattering_kind,
                                                       @config.common.taktuk_connector,
                                                       "0",
                                                       instance_thread)
    end

    # Send a tarball with Kastafior and uncompress it on the nodes
    #
    # Arguments
    # * tarball_file: path to the tarball
    # * tarball_kind: kind of archive (tgz, tbz2, ddgz, ddbz2)
    # * deploy_mount_point: deploy mount point
    # * deploy_mount_part: deploy mount part
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the operation is correctly performed, false otherwise
    def send_tarball_and_uncompress_with_kastafior(tarball_file, tarball_kind, deploy_mount_point, deploy_part, instance_thread)
      if @config.cluster_specific[@cluster].use_ip_to_deploy then
        pr = ParallelRunner::PRunner.new(@output, instance_thread, @process_container)
        @nodes_ok.set.each { |node|
          kastafior_hostname = node.ip
          cmd = "#{@config.common.taktuk_connector} #{node.ip} \"echo #{node.ip} > /tmp/kastafior_hostname\""
          pr.add(cmd, node)
        }
        pr.run
        pr.wait
      end

      list = String.new
      list = "-m #{Socket.gethostname()}"
    
      if @config.cluster_specific[@cluster].use_ip_to_deploy then
        @nodes_ok.make_sorted_array_of_nodes.each { |node|
          list += " -m #{node.ip}"
        }
      else
        @nodes_ok.make_sorted_array_of_nodes.each { |node|
          list += " -m #{node.hostname}"
        }
      end

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
        @output.verbosel(0, "The #{tarball_kind} archive kind is not supported")
        return false
      end

      if @config.common.taktuk_auto_propagate then
        cmd = "kastafior -s -c \\\"#{@config.common.taktuk_connector}\\\" #{list} -- -s \"cat #{tarball_file}\" -c \"#{cmd}\" -f"
      else
        cmd = "kastafior -c \\\"#{@config.common.taktuk_connector}\\\" #{list} -- -s \"cat #{tarball_file}\" -c \"#{cmd}\" -f"
      end
      c = ParallelRunner::Command.new(cmd)
      c.run
      std_output = String.new
      err_output = String.new
      std_reader = Thread.new {
        std_output_full = false
        begin
          while (line = c.stdout.gets) && (not std_output_full)
            std_output += line
            std_output_full = true if std_output.length > 1000
          end
        ensure
          c.stdout.close
        end
      }
      err_reader = Thread.new {
        err_output_full = false
        begin
          while (line = c.stderr.gets) && (not err_output_full)
            err_output += line
            err_output_full = true if err_output.length > 1000
          end
        ensure
          c.stderr.close
        end
      }
      @process_container.add_process(instance_thread, c.pid)
      c.wait
      std_reader.join
      err_reader.join
      @process_container.remove_process(instance_thread, c.pid)
      @output.debug_command(cmd, std_output, err_output, c.status)
      if (c.status != 0) then
        failed_microstep("Error while processing to the file broadcast with Kastafior (exited with status #{c.status})")
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
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the operation is correctly performed, false otherwise
    def send_tarball_and_uncompress_with_bittorrent(tarball_file, tarball_kind, deploy_mount_point, deploy_part, instance_thread)
      if not parallel_exec_command_wrapper("rm -f /tmp/#{File.basename(tarball_file)}*",
                                           @config.common.taktuk_connector,
                                           instance_thread) then
        failed_microstep("Error while cleaning the /tmp")
        return false
      end
      torrent = "#{tarball_file}.torrent"
      btdownload_state = "/tmp/btdownload_state#{Time.now.to_f}"
      tracker_pid, tracker_port = Bittorrent::launch_tracker(btdownload_state)
      if not Bittorrent::make_torrent(tarball_file, @config.common.bt_tracker_ip, tracker_port) then
        failed_microstep("The torrent file (#{torrent}) has not been created")
        return false
      end
      if @config.common.kadeploy_disable_cache then
        seed_pid = Bittorrent::launch_seed(torrent, File.dirname(tarball_file))
      else
        seed_pid = Bittorrent::launch_seed(torrent, @config.common.kadeploy_cache_dir)
      end
      if (seed_pid == -1) then
        failed_microstep("The seed of #{torrent} has not been launched")
        return false
      end
      if not parallel_send_file_command_wrapper(torrent, "/tmp", "tree", @config.common.taktuk_connector, instance_thread) then
        failed_microstep("Error while sending the torrent file")
        return false
      end
      if not parallel_exec_command_wrapper("/usr/local/bin/bittorrent_detach /tmp/#{File.basename(torrent)}", 
                                           @config.common.taktuk_connector,
                                           instance_thread) then
        failed_microstep("Error while launching the bittorrent download")
        return false
      end
      sleep(20)
      expected_clients = @nodes_ok.length
      if not Bittorrent::wait_end_of_download(@config.common.bt_download_timeout, torrent, @config.common.bt_tracker_ip, tracker_port, expected_clients) then
        failed_microstep("A timeout for the bittorrent download has been reached")
        ProcessManagement::killall(seed_pid)
        return false
      end
      @output.verbosel(3, "Shutdown the seed for #{torrent}")
      ProcessManagement::killall(seed_pid)
      @output.verbosel(3, "Shutdown the tracker for #{torrent}")
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
      if not parallel_exec_command_wrapper(cmd, @config.common.taktuk_connector, instance_thread) then
        failed_microstep("Error while uncompressing the tarball")
        return false
      end
      if not parallel_exec_command_wrapper("rm -f /tmp/#{File.basename(tarball_file)}*",
                                           @config.common.taktuk_connector,
                                           instance_thread) then
        failed_microstep("Error while cleaning the /tmp")
        return false
      end
      return true
    end

    # Execute a custom command on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * cmd: command to execute
    # Output
    # * return true if the command has been correctly performed, false otherwise
    def custom_exec_cmd(instance_thread, cmd)
      @output.verbosel(3, "CUS exec_cmd: #{@nodes_ok.to_s_fold}")
      return parallel_exec_command_wrapper(cmd, @config.common.taktuk_connector, instance_thread)
    end

    # Send a custom file on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * file: filename
    # * dest_dir: destination directory on the nodes
    # Output
    # * return true if the file has been correctly sent, false otherwise
    def custom_send_file(instance_thread, file, dest_dir)
      @output.verbosel(3, "CUS send_file: #{@nodes_ok.to_s_fold}")
      return parallel_send_file_command_wrapper(file,
                                                dest_dir,
                                                "chain",
                                                @config.common.taktuk_connector,
                                                instance_thread)
    end

    # Run the custom methods attached to a micro step
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * macro_step: name of the macro step
    # * micro_step: name of the micro step
    # Output
    # * return true if the methods have been successfully executed, false otherwise    
    def run_custom_methods(instance_thread, macro_step, micro_step)
      result = true
      @config.exec_specific.custom_operations[macro_step][micro_step].each { |entry|
        cmd = entry[0]
        arg = entry[1]
        dir = entry[2]
        case cmd
        when "exec"
          result = result && custom_exec_cmd(instance_thread, arg)
        when "send"
          result = result && custom_send_file(instance_thread, arg, dir)
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
    def custom_methods_attached?(macro_step, micro_step)
      return ((@config.exec_specific.custom_operations != nil) && 
              @config.exec_specific.custom_operations.has_key?(macro_step) && 
              @config.exec_specific.custom_operations[macro_step].has_key?(micro_step))
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
      env = "KADEPLOY_CLUSTER=\"#{@cluster}\""
      env += " KADEPLOY_ENV=\"#{@config.exec_specific.environment.name}\""
      env += " KADEPLOY_DEPLOY_PART=\"#{get_deploy_part_str()}\""
      env += " KADEPLOY_ENV_EXTRACTION_DIR=\"#{@config.common.environment_extraction_dir}\""
      env += " KADEPLOY_PREPOST_EXTRACTION_DIR=\"#{@config.common.rambin_path}\""
      return env
    end

    # Perform a fdisk on the nodes
    #
    # Arguments
    # * env: kind of environment on wich the fdisk operation is performed
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the fdisk has been successfully performed, false otherwise
    def do_fdisk(env, instance_thread)
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
        temp = Tempfile.new("fdisk_#{@cluster}")
      rescue StandardException
        failed_microstep("Cannot create the tempfile fdisk_#{@cluster}")
        return false
      end
      if not system("cat #{@config.cluster_specific[@cluster].partition_file}|sed 's/PARTTYPE/#{@config.exec_specific.environment.fdisk_type}/' > #{temp.path}") then
        failed_microstep("Cannot generate the partition_file")
        return false
      end
      if not parallel_exec_cmd_with_input_file_wrapper(temp.path,
                                                       "fdisk #{@config.cluster_specific[@cluster].block_device}",
                                                       "tree",
                                                       @config.common.taktuk_connector,
                                                       expected_status,
                                                       instance_thread) then
        failed_microstep("Cannot perform the fdisk operation")
        return false
      end
      temp.unlink
      return true
    end

    # Perform a parted on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the parted has been successfully performed, false otherwise
    def do_parted(instance_thread)
      return parallel_exec_cmd_with_input_file_wrapper(@config.cluster_specific[@cluster].partition_file,
                                                       "cat - > /rambin/parted_script && chmod +x /rambin/parted_script && /rambin/parted_script",
                                                       "tree",
                                                       @config.common.taktuk_connector,
                                                       "0",
                                                       instance_thread)
    end

    public

    # Test if a timeout is reached
    #
    # Arguments
    # * timeout: timeout
    # * instance_thread: instance of thread that waits for the timeout
    # * step_name: name of the current step
    # Output   
    # * return true if the timeout is reached, false otherwise
    def timeout?(timeout, instance_thread, step_name, instance_node_set)
      start = Time.now.to_i
      while ((instance_thread.status != false) && (Time.now.to_i < (start + timeout)))
        sleep(1)
      end
      if (instance_thread.status != false) then
        @output.verbosel(3, "Timeout before the end of the step on cluster #{@cluster}, let's kill the instance")
        Thread.kill(instance_thread)
        @process_container.killall(instance_thread)
        @nodes_ok.free
        instance_node_set.set_error_msg("Timeout in the #{step_name} step")
        instance_node_set.add_diff_and_free(@nodes_ko)
        return true
      else
        instance_node_set.free()
        instance_thread.join
        return false
      end
    end

    def method_missing(method_sym, *args)
      if (@nodes_ok.empty?) then
        return false
      else
        @nodes_ok.set.each { |node|
          @config.set_node_state(node.hostname, @macro_step, method_sym.to_s, "ok")
        }
        real_method = "ms_#{method_sym.to_s}".to_sym
        if (self.class.method_defined? real_method) then
          if (@config.exec_specific.breakpoint_on_microstep != "none") then
            brk_on_macrostep = @config.exec_specific.breakpoint_on_microstep.split(":")[0]
            brk_on_microstep = @config.exec_specific.breakpoint_on_microstep.split(":")[1]
            if ((brk_on_macrostep == @macro_step) && (brk_on_microstep == method_sym.to_s)) then
              @output.verbosel(0, "BRK #{method_sym.to_s}: #{@nodes_ok.to_s_fold}")
              @config.exec_specific.breakpointed = true
              return false
            end
          end
          if custom_methods_attached?(@macro_step, method_sym.to_s) then
            if run_custom_methods(Thread.current, @macro_step, method_sym.to_s) then
              @output.verbosel(2, "--- #{method_sym.to_s} (#{@cluster} cluster)")
              @output.verbosel(3, "  >>>  #{@nodes_ok.to_s_fold}")
              send(real_method, Thread.current, *args)
            else
              return false
            end
          else
            @output.verbosel(2, "--- #{method_sym.to_s} (#{@cluster} cluster)")
            @output.verbosel(3, "  >>>  #{@nodes_ok.to_s_fold}")
            start = Time.now.to_i
            ret = send(real_method, Thread.current, *args)
            @output.verbosel(4, "  Time in #{@macro_step}-#{method_sym.to_s}: #{Time.now.to_i - start}s")
            return ret
          end
        else
          @output.verbosel(0, "Wrong method: #{method_sym} #{real_method}!!!")
          exit 1
        end
      end
    end

    # Send the SSH key in the deployment environment
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * scattering_kind: kind of taktuk scatter (tree, chain)
    # Output
    # * return true if the keys have been successfully copied, false otherwise
    def ms_send_key_in_deploy_env(instance_thread, scattering_kind)
      if (@config.exec_specific.key != "") then
        cmd = "cat - >>/root/.ssh/authorized_keys"
        return parallel_exec_cmd_with_input_file_wrapper(@config.exec_specific.key,
                                                         cmd,
                                                         scattering_kind,
                                                         @config.common.taktuk_connector,
                                                         "0",
                                                         instance_thread)
      else
        @output.verbosel(3, "  *** No key has been specified")
      end
      return true
    end

    # Change the PXE configuration
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * step: kind of change (prod_to_deploy_env, prod_to_nfsroot_env, chainload_pxe)
    # * pxe_profile_msg (opt): string containing the pxe profile
    # Output
    # * return true if the operation has been performed correctly, false otherwise
    def ms_switch_pxe(instance_thread, step, pxe_profile_msg = "")
      case step
      when "prod_to_deploy_env"
        if not PXEOperations::set_pxe_for_linux(@nodes_ok.make_array_of_ip,   
                                                @config.cluster_specific[@cluster].deploy_kernel,
                                                "",
                                                @config.cluster_specific[@cluster].deploy_initrd,
                                                "",
                                                @config.common.tftp_repository,
                                                @config.common.tftp_images_path,
                                                @config.common.tftp_cfg,
                                                @config.cluster_specific[@cluster].pxe_header) then
          @output.verbosel(0, "Cannot perform the set_pxe_for_linux operation")
          return false
        end
      when "prod_to_nfsroot_env"
        if not PXEOperations::set_pxe_for_nfsroot(@nodes_ok.make_array_of_ip,
                                                  @config.cluster_specific[@cluster].nfsroot_kernel,
                                                  @config.cluster_specific[@cluster].nfsroot_params,
                                                  @config.common.tftp_repository,
                                                  @config.common.tftp_images_path,
                                                  @config.common.tftp_cfg,
                                                  @config.cluster_specific[@cluster].pxe_header) then
          @output.verbosel(0, "Cannot perform the set_pxe_for_nfsroot operation")
          return false
        end
      when "set_pxe"
        if not PXEOperations::set_pxe_for_custom(@nodes_ok.make_array_of_ip,
                                                 pxe_profile_msg,
                                                 @config.common.tftp_repository,
                                                 @config.common.tftp_cfg,
                                                 @config.exec_specific.pxe_profile_singularities) then
          @output.verbosel(0, "Cannot perform the set_pxe_for_custom operation")
          return false
        end
      when "deploy_to_deployed_env"
        array_of_ip = Array.new
        if (@config.exec_specific.vlan == nil) then
          array_of_ip = @nodes_ok.make_array_of_ip
        else
          @nodes_ok.make_array_of_hostname.each { |hostname|
            array_of_ip.push(@config.exec_specific.ip_in_vlan[hostname])
          }
        end
        if (@config.exec_specific.pxe_profile_msg != "") then
          if not PXEOperations::set_pxe_for_custom(array_of_ip,
                                                   @config.exec_specific.pxe_profile_msg,
                                                   @config.common.tftp_repository,
                                                   @config.common.tftp_cfg,
                                                   @config.exec_specific.pxe_profile_singularities) then
            @output.verbosel(0, "Cannot perform the set_pxe_for_custom operation")
            return false
          end
        else
          case @config.common.bootloader
          when "pure_pxe"
            case @config.exec_specific.environment.environment_kind
            when "linux"
              kernel = @config.exec_specific.prefix_in_cache + File.basename(@config.exec_specific.environment.kernel)
              initrd = @config.exec_specific.prefix_in_cache + File.basename(@config.exec_specific.environment.initrd) if (@config.exec_specific.environment.initrd != nil)
              images_dir = File.join(@config.common.tftp_repository, @config.common.tftp_images_path)
              if not system("touch -a #{File.join(images_dir, kernel)}") then
                @output.verbosel(0, "Cannot touch #{File.join(images_dir, kernel)}")
                return false
              end
              if (@config.exec_specific.environment.initrd != nil) then
                if not system("touch -a #{File.join(images_dir, initrd)}") then
                  @output.verbosel(0, "Cannot touch #{File.join(images_dir, initrd)}")
                  return false
                end
              end
              if not PXEOperations::set_pxe_for_linux(array_of_ip,
                                                      kernel,
                                                      get_kernel_params(),
                                                      initrd,
                                                      get_deploy_part_str(),
                                                      @config.common.tftp_repository,
                                                      @config.common.tftp_images_path,
                                                      @config.common.tftp_cfg,
                                                      @config.cluster_specific[@cluster].pxe_header) then
                @output.verbosel(0, "Cannot perform the set_pxe_for_linux operation")
                return false
              end
            when "xen"
              kernel = @config.exec_specific.prefix_in_cache + File.basename(@config.exec_specific.environment.kernel)
              initrd = @config.exec_specific.prefix_in_cache + File.basename(@config.exec_specific.environment.initrd) if (@config.exec_specific.environment.initrd != nil)
              hypervisor = @config.exec_specific.prefix_in_cache + File.basename(@config.exec_specific.environment.hypervisor)
              images_dir = File.join(@config.common.tftp_repository, @config.common.tftp_images_path)
              if not system("touch -a #{File.join(images_dir, kernel)}") then
                @output.verbosel(0, "Cannot touch #{File.join(images_dir, kernel)}")
                return false
              end
              if (@config.exec_specific.environment.initrd != nil) then
                if not system("touch -a #{File.join(images_dir, initrd)}") then
                  @output.verbosel(0, "Cannot touch #{File.join(images_dir, initrd)}")
                  return false
                end
              end
              if not system("touch -a #{File.join(images_dir, hypervisor)}") then
                @output.verbosel(0, "Cannot touch #{File.join(images_dir, hypervisor)}")
                return false
              end
              if not PXEOperations::set_pxe_for_xen(array_of_ip,
                                                    hypervisor,
                                                    @config.exec_specific.environment.hypervisor_params,
                                                    kernel,
                                                    get_kernel_params(),
                                                    initrd,
                                                    get_deploy_part_str(),
                                                    @config.common.tftp_repository,
                                                    @config.common.tftp_images_path,
                                                    @config.common.tftp_cfg,
                                                    @config.cluster_specific[@cluster].pxe_header) then
                @output.verbosel(0, "Cannot perform the set_pxe_for_xen operation")
                return false
              end
            end
            Cache::clean_cache(File.join(@config.common.tftp_repository, @config.common.tftp_images_path),
                               @config.common.tftp_images_max_size * 1024 * 1024,
                               1,
                               /^(e\d+--.+)|(e-anon-.+)|(pxe-.+)$/,
                               @output)
          when "chainload_pxe"
            if (@config.exec_specific.environment.environment_kind != "xen") then
              PXEOperations::set_pxe_for_chainload(array_of_ip,
                                                   get_deploy_part_num(),
                                                   @config.common.tftp_repository,
                                                   @config.common.tftp_images_path,
                                                   @config.common.tftp_cfg,
                                                   @config.cluster_specific[@cluster].pxe_header)
            else
              # @output.verbosel(3, "Hack, Grub2 cannot boot a Xen Dom0, so let's use the pure PXE fashion")
              kernel = @config.exec_specific.prefix_in_cache + File.basename(@config.exec_specific.environment.kernel)
              initrd = @config.exec_specific.prefix_in_cache + File.basename(@config.exec_specific.environment.initrd) if (@config.exec_specific.environment.initrd != nil)
              hypervisor = @config.exec_specific.prefix_in_cache + File.basename(@config.exec_specific.environment.hypervisor)
              images_dir = File.join(@config.common.tftp_repository, @config.common.tftp_images_path)
              if not system("touch -a #{File.join(images_dir, kernel)}") then
                @output.verbosel(0, "Cannot touch #{File.join(images_dir, kernel)}")
                return false
              end
              if (@config.exec_specific.environment.initrd != nil) then
                if not system("touch -a #{File.join(images_dir, initrd)}") then
                  @output.verbosel(0, "Cannot touch #{File.join(images_dir, initrd)}")
                  return false
                end
              end
              if not system("touch -a #{File.join(images_dir, hypervisor)}") then
                @output.verbosel(0, "Cannot touch #{File.join(images_dir, hypervisor)}")
                return false
              end
              if not PXEOperations::set_pxe_for_xen(array_of_ip,
                                                    hypervisor,
                                                    @config.exec_specific.environment.hypervisor_params,
                                                    kernel,
                                                    get_kernel_params(),
                                                    initrd,
                                                    get_deploy_part_str(),
                                                    @config.common.tftp_repository,
                                                    @config.common.tftp_images_path,
                                                    @config.common.tftp_cfg,
                                                    @config.cluster_specific[@cluster].pxe_header) then
                @output.verbosel(0, "Cannot perform the set_pxe_for_xen operation")
                return false
              end
              Cache::clean_cache(File.join(@config.common.tftp_repository, @config.common.tftp_images_path),
                                 @config.common.tftp_images_max_size * 1024 * 1024,
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
    # * instance_thread: thread id of the current thread
    # * reboot_kind: kind of reboot (soft, hard, very_hard, kexec)
    # * first_attempt (opt): specify if it is the first attempt or not 
    # Output
    # * return true (should be false sometimes :D)
    def ms_reboot(instance_thread, reboot_kind, first_attempt = true)
      case reboot_kind
      when "soft"
        if first_attempt then
          escalation_cmd_wrapper("reboot", "soft", instance_thread)
        else
          #After the first attempt, we must not perform another soft reboot in order to avoid loop reboot on the same environment 
          escalation_cmd_wrapper("reboot", "hard", instance_thread)
        end
      when "hard"
        escalation_cmd_wrapper("reboot", "hard", instance_thread)
      when "very_hard"
        escalation_cmd_wrapper("reboot", "very_hard", instance_thread)
      when "kexec"
        if (@config.exec_specific.environment.environment_kind == "linux") then
          kernel = "#{@config.common.environment_extraction_dir}#{@config.exec_specific.environment.kernel}"
          initrd = "#{@config.common.environment_extraction_dir}#{@config.exec_specific.environment.initrd}"
          root_part = get_deploy_part_str()
          #Warning, this require the /usr/local/bin/kexec_detach script
          return parallel_exec_command_wrapper("(/usr/local/bin/kexec_detach #{kernel} #{initrd} #{root_part} #{get_kernel_params()})",
                                               @config.common.taktuk_connector, instance_thread)
        else
          @output.verbosel(3, "   The Kexec optimization can only be used with a linux environment")
          escalation_cmd_wrapper("reboot", "soft", instance_thread)
        end
      end
      return true
    end

    # Perform a detached reboot from the deployment environment
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the reboot has been successfully performed, false otherwise
    def ms_reboot_from_deploy_env(instance_thread)
      return parallel_exec_command_wrapper("/usr/local/bin/reboot_detach", @config.common.taktuk_connector, instance_thread)
    end

    # Perform a power operation on the current set of nodes_ok
    def ms_power(instance_thread, operation, level)
      case operation
      when "on"
        escalation_cmd_wrapper("power_on", level, instance_thread)
      when "off"
        escalation_cmd_wrapper("power_off", level, instance_thread)
      when "status"
        parallel_get_power_status(instance_thread)
      end
    end

    # Check the state of a set of nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * step: step in which the nodes are expected to be
    # Output
    # * return true if the check has been successfully performed, false otherwise
    def ms_check_nodes(instance_thread, step)
      case step
      when "deployed_env_booted"
        #we look if the / mounted partition is the deployment partition
        return parallel_exec_command_wrapper_expecting_status_and_output("(mount | grep \\ \\/\\  | cut -f 1 -d\\ )",
                                                                         ["0"],
                                                                         get_deploy_part_str(),
                                                                         @config.common.taktuk_connector,
                                                                         instance_thread)
      when "prod_env_booted"
        #We look if the / mounted partition is the default production partition.
        #We don't use the Taktuk method because this would require to have the deploy
        #private key in the production environment.
        callback = Proc.new { |ns|
          
          pr = ParallelRunner::PRunner.new(@output, nil, @process_container)
          ns.set.each { |node|
            cmd = "#{@config.common.taktuk_connector} root@#{node.hostname} \"mount | grep \\ \\/\\  | cut -f 1 -d\\ \""
            pr.add(cmd, node)
          }
          @output.verbosel(3, "  *** A bunch of check prod env tests will be performed on #{ns.to_s_fold}")
          pr.run
          pr.wait
          classify_nodes(pr.get_results_expecting_output(@config.cluster_specific[@cluster].block_device + @config.cluster_specific[@cluster].prod_part, "Bad root partition"))
        }
        node_set = Nodes::NodeSet.new
        @nodes_ok.duplicate_and_free(node_set)
        @reboot_window.launch_on_node_set(node_set, &callback)
        return (not @nodes_ok.empty?)
      end
    end

    # Load some specific drivers on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the drivers have been successfully loaded, false otherwise
    def ms_load_drivers(instance_thread)
      cmd = String.new
      @config.cluster_specific[@cluster].drivers.each_index { |i|
        cmd += "modprobe #{@config.cluster_specific[@cluster].drivers[i]};"
      }
      return parallel_exec_command_wrapper(cmd, @config.common.taktuk_connector, instance_thread)
    end

    # Create the partition table on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * env: kind of environment on wich the patition creation is performed (prod_env or untrusted_env)
    # Output
    # * return true if the operation has been successfully performed, false otherwise
    def ms_create_partition_table(instance_thread, env)
      if @config.exec_specific.disable_disk_partitioning then
        @output.verbosel(3, "  *** Bypass the disk partitioning")
        return true
      else
        case @config.cluster_specific[@cluster].partition_creation_kind
        when "fdisk"
          return do_fdisk(env, instance_thread)
        when "parted"
          return do_parted(instance_thread)
        end
      end
    end

    # Perform the deployment part on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the format has been successfully performed, false otherwise
    def ms_format_deploy_part(instance_thread)
      if ((@config.exec_specific.environment.tarball["kind"] == "tgz") ||
          (@config.exec_specific.environment.tarball["kind"] == "tbz2")) then
        if @config.common.mkfs_options.has_key?(@config.exec_specific.environment.filesystem) then
          opts = @config.common.mkfs_options[@config.exec_specific.environment.filesystem]
          return parallel_exec_command_wrapper("mkdir -p #{@config.common.environment_extraction_dir}; \
                                               umount #{get_deploy_part_str()} 2>/dev/null; \
                                               mkfs -t #{@config.exec_specific.environment.filesystem} #{opts} #{get_deploy_part_str()}",
                                               @config.common.taktuk_connector,
                                               instance_thread)
        else
          return parallel_exec_command_wrapper("mkdir -p #{@config.common.environment_extraction_dir}; \
                                               umount #{get_deploy_part_str()} 2>/dev/null; \
                                               mkfs -t #{@config.exec_specific.environment.filesystem} #{get_deploy_part_str()}",
                                               @config.common.taktuk_connector,
                                               instance_thread)
        end
      else
        @output.verbosel(3, "  *** Bypass the format of the deploy part")
        return true
      end
    end

    # Format the /tmp part on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the format has been successfully performed, false otherwise
    def ms_format_tmp_part(instance_thread)
      if (@config.exec_specific.reformat_tmp) then
        fstype = @config.exec_specific.reformat_tmp_fstype
        if @config.common.mkfs_options.has_key?(fstype) then
          opts = @config.common.mkfs_options[fstype]
          tmp_part = @config.cluster_specific[@cluster].block_device + @config.cluster_specific[@cluster].tmp_part
          return parallel_exec_command_wrapper("mkdir -p /tmp; umount #{tmp_part} 2>/dev/null; mkfs.#{fstype} #{opts} #{tmp_part}",
                                               @config.common.taktuk_connector,
                                               instance_thread)
        else
          tmp_part = @config.cluster_specific[@cluster].block_device + @config.cluster_specific[@cluster].tmp_part
          return parallel_exec_command_wrapper("mkdir -p /tmp; umount #{tmp_part} 2>/dev/null; mkfs.#{fstype} #{tmp_part}",
                                               @config.common.taktuk_connector,
                                               instance_thread)
        end
      else
        @output.verbosel(3, "  *** Bypass the format of the tmp part")
      end
      return true
    end

    # Format the swap part on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the format has been successfully performed, false otherwise
    def ms_format_swap_part(instance_thread)
      if (@config.cluster_specific[@cluster].swap_part != nil) && (@config.cluster_specific[@cluster].swap_part!= "none") then
        swap_part = @config.cluster_specific[@cluster].block_device + @config.cluster_specific[@cluster].swap_part
        return parallel_exec_command_wrapper("mkswap #{swap_part}",
                                             @config.common.taktuk_connector,
                                             instance_thread)
      else
        @output.verbosel(3, "  *** Bypass the format of the swap part")
      end
      return true
    end

    # Mount the deployment part on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the mount has been successfully performed, false otherwise
    def ms_mount_deploy_part(instance_thread)
      #we do not mount the deploy part for a dd.gz or dd.bz2 image
      if ((@config.exec_specific.environment.tarball["kind"] == "tgz") ||
          (@config.exec_specific.environment.tarball["kind"] == "tbz2")) then
        return parallel_exec_command_wrapper("mount #{get_deploy_part_str()} #{@config.common.environment_extraction_dir}",
                                             @config.common.taktuk_connector,
                                             instance_thread)
      else
        @output.verbosel(3, "  *** Bypass the mount of the deploy part")
        return true
      end
    end

    # Mount the /tmp part on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the mount has been successfully performed, false otherwise
    def ms_mount_tmp_part(instance_thread)
      tmp_part = @config.cluster_specific[@cluster].block_device + @config.cluster_specific[@cluster].tmp_part
      return parallel_exec_command_wrapper("mount #{tmp_part} /tmp",
                                           @config.common.taktuk_connector,
                                           instance_thread)
    end

    # Send the SSH key in the deployed environment
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * scattering_kind:  kind of taktuk scatter (tree, chain)
    # Output
    # * return true if the keys have been successfully copied, false otherwise
    def ms_send_key(instance_thread, scattering_kind)
      if ((@config.exec_specific.key != "") && ((@config.exec_specific.environment.tarball["kind"] == "tgz") ||
                                                (@config.exec_specific.environment.tarball["kind"] == "tbz2"))) then
        cmd = "cat - >>#{@config.common.environment_extraction_dir}/root/.ssh/authorized_keys"
        return parallel_exec_cmd_with_input_file_wrapper(@config.exec_specific.key,
                                                         cmd,
                                                         scattering_kind,
                                                         @config.common.taktuk_connector,
                                                         "0",
                                                       instance_thread)
      end
      return true
    end

    # Wait some nodes after a reboot
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * ports_up: up ports used to perform a reach test on the nodes
    # * ports_down: down ports used to perform a reach test on the nodes
    # * timeout: reboot timeout
    # * last_reboot: specify if we wait the last reboot
    # Output
    # * return true if some nodes are here, false otherwise
    def ms_wait_reboot(instance_thread, ports_up, ports_down, timeout, last_reboot = false)
      return parallel_wait_nodes_after_reboot_wrapper(timeout, 
                                                      ports_up, 
                                                      ports_down,
                                                      @nodes_check_window,
                                                      instance_thread,
                                                      last_reboot)
    end
    
    # Eventually install a bootloader
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if case of success (the success should be tested better)
    def ms_install_bootloader(instance_thread)
      case @config.common.bootloader
      when "pure_pxe"
        case @config.exec_specific.environment.environment_kind
        when "linux"
          return copy_kernel_initrd_to_pxe([@config.exec_specific.environment.kernel,
                                            @config.exec_specific.environment.initrd])
        when "xen"
          return copy_kernel_initrd_to_pxe([@config.exec_specific.environment.kernel,
                                            @config.exec_specific.environment.initrd,
                                            @config.exec_specific.environment.hypervisor])
        when "other"
          failed_microstep("Only linux and xen environments can be booted with a pure PXE configuration")
          return false
        end
      when "chainload_pxe"
        if @config.exec_specific.disable_bootloader_install then
          @output.verbosel(3, "  *** Bypass the bootloader installation")
          return true
        else
          case @config.exec_specific.environment.environment_kind
          when "linux"
            return install_grub2_on_nodes("linux", instance_thread)
          when "xen"
#            return install_grub2_on_nodes("xen", instance_thread)
            @output.verbosel(3, "   Hack, Grub2 cannot boot a Xen Dom0, so let's use the pure PXE fashion")
            return copy_kernel_initrd_to_pxe([@config.exec_specific.environment.kernel,
                                              @config.exec_specific.environment.initrd,
                                              @config.exec_specific.environment.hypervisor])

          when "other"
            #in this case, the bootloader must be installed by the user (dd partition)
            return true
          end
        end
      else
        @output.verbosel(0, "Invalid bootloader value: #{@config.common.bootloader}")
        return false
      end
    end

    # Dummy method to put all the nodes in the node_ko set
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true (should be false sometimes :D)
    def ms_produce_bad_nodes(instance_thread)
      @nodes_ok.duplicate_and_free(@nodes_ko)
      return true
    end

    # Umount the deployment part on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the deploy part has been successfully umounted, false otherwise
    def ms_umount_deploy_part(instance_thread)
      if ((@config.exec_specific.environment.tarball["kind"] == "tgz") ||
          (@config.exec_specific.environment.tarball["kind"] == "tbz2")) then
        return parallel_exec_command_wrapper("umount -l #{get_deploy_part_str()}",
                                             @config.common.taktuk_connector,
                                             instance_thread)
      else
        @output.verbosel(3, "  *** Bypass the umount of the deploy part")
        return true
      end
    end

    # Send and uncompress the user environment on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * scattering_kind: kind of taktuk scatter (tree, chain, kastafior)
    # Output
    # * return true if the environment has been successfully uncompressed, false otherwise
    def ms_send_environment(instance_thread, scattering_kind)
      start = Time.now.to_i
      case scattering_kind
      when "bittorrent"
        res = send_tarball_and_uncompress_with_bittorrent(@config.exec_specific.environment.tarball["file"],
                                                          @config.exec_specific.environment.tarball["kind"],
                                                          @config.common.environment_extraction_dir,
                                                          get_deploy_part_str(),
                                                          instance_thread)
      when "chain"
        res = send_tarball_and_uncompress_with_taktuk("chain",
                                                      @config.exec_specific.environment.tarball["file"],
                                                      @config.exec_specific.environment.tarball["kind"],
                                                      @config.common.environment_extraction_dir,
                                                      get_deploy_part_str(),
                                                      instance_thread)
      when "kastafior"
        res = send_tarball_and_uncompress_with_kastafior(@config.exec_specific.environment.tarball["file"],
                                                         @config.exec_specific.environment.tarball["kind"],
                                                         @config.common.environment_extraction_dir,
                                                         get_deploy_part_str(),
                                                         instance_thread)        
      end
      @output.verbosel(3, "  *** Broadcast time: #{Time.now.to_i - start} seconds") if res
      return res
    end


    # Send and execute the admin preinstalls on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * scattering_kind: kind of taktuk scatter (tree, chain)
    # Output
    # * return true if the admin preinstall has been successfully uncompressed, false otherwise
    def ms_manage_admin_pre_install(instance_thread, scattering_kind)
      #First we check if the preinstall has been defined in the environment
      if (@config.exec_specific.environment.preinstall != nil) then
        preinstall = @config.exec_specific.environment.preinstall
        if not send_tarball_and_uncompress_with_taktuk(scattering_kind, preinstall["file"], preinstall["kind"], @config.common.rambin_path, "", instance_thread) then
          return false
        end
        if (preinstall["script"] == "breakpoint") then
          @output.verbosel(0, "Breakpoint on admin preinstall after sending the file #{preinstall["file"]}")
          @config.exec_specific.breakpointed = true
          return false
        elsif (preinstall["script"] != "none")
          if not parallel_exec_command_wrapper("(#{set_env()} #{@config.common.rambin_path}/#{preinstall["script"]})",
                                               @config.common.taktuk_connector,
                                               instance_thread) then
            return false
          end
        end
      elsif (@config.cluster_specific[@cluster].admin_pre_install != nil) then
        @config.cluster_specific[@cluster].admin_pre_install.each { |preinstall|
          if not send_tarball_and_uncompress_with_taktuk(scattering_kind, preinstall["file"], preinstall["kind"], @config.common.rambin_path, "", instance_thread) then
            return false
          end
          if (preinstall["script"] == "breakpoint") then
            @output.verbosel(0, "Breakpoint on admin preinstall after sending the file #{preinstall["file"]}")
            @config.exec_specific.breakpointed = true
            return false
          elsif (preinstall["script"] != "none")
            if not parallel_exec_command_wrapper("(#{set_env()} #{@config.common.rambin_path}/#{preinstall["script"]})",
                                                 @config.common.taktuk_connector,
                                                 instance_thread) then
              return false
            end
          end
        }
      else
        @output.verbosel(3, "  *** Bypass the admin preinstalls")
      end
      return true
    end

    # Send and execute the admin postinstalls on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * scattering_kind: kind of taktuk scatter (tree, chain)
    # Output
    # * return true if the admin postinstall has been successfully uncompressed, false otherwise   
    def ms_manage_admin_post_install(instance_thread, scattering_kind)
      if (@config.exec_specific.environment.environment_kind != "other") && (@config.cluster_specific[@cluster].admin_post_install != nil) then
        @config.cluster_specific[@cluster].admin_post_install.each { |postinstall|
          if not send_tarball_and_uncompress_with_taktuk(scattering_kind, postinstall["file"], postinstall["kind"], @config.common.rambin_path, "", instance_thread) then
            return false
          end
          if (postinstall["script"] == "breakpoint") then 
            @output.verbosel(0, "Breakpoint on admin postinstall after sending the file #{postinstall["file"]}")         
            @config.exec_specific.breakpointed = true
            return false
          elsif (postinstall["script"] != "none")
            if not parallel_exec_command_wrapper("(#{set_env()} #{@config.common.rambin_path}/#{postinstall["script"]})",
                                                 @config.common.taktuk_connector,
                                                 instance_thread) then
              return false
            end
          end
        }
      else
        @output.verbosel(3, "  *** Bypass the admin postinstalls")
      end
      return true
    end

    # Send and execute the user postinstalls on the nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # * scattering_kind: kind of taktuk scatter (tree, chain)
    # Output
    # * return true if the user postinstall has been successfully uncompressed, false otherwise
    def ms_manage_user_post_install(instance_thread, scattering_kind)
      if (@config.exec_specific.environment.environment_kind != "other") && (@config.exec_specific.environment.postinstall != nil) then
        @config.exec_specific.environment.postinstall.each { |postinstall|
          if not send_tarball_and_uncompress_with_taktuk(scattering_kind, postinstall["file"], postinstall["kind"], @config.common.rambin_path, "", instance_thread) then
            return false
          end
          if (postinstall["script"] == "breakpoint") then
            @output.verbosel(0, "Breakpoint on user postinstall after sending the file #{postinstall["file"]}")
            @config.exec_specific.breakpointed = true
            return false
          elsif (postinstall["script"] != "none")
            if not parallel_exec_command_wrapper("(#{set_env()} #{@config.common.rambin_path}/#{postinstall["script"]})",
                                                 @config.common.taktuk_connector,
                                                 instance_thread) then
              return false
            end
          end
        }
      else
        @output.verbosel(3, "  *** Bypass the user postinstalls")
      end
      return true
    end

    # Set a VLAN for the deployed nodes
    #
    # Arguments
    # * instance_thread: thread id of the current thread
    # Output
    # * return true if the operation has been correctly performed, false otherwise
    def ms_set_vlan(instance_thread)
      if (@config.exec_specific.vlan != nil) then
        list = String.new
        @nodes_ok.make_array_of_hostname.each { |hostname|
          list += " -m #{hostname}"
        }
        cmd = @config.common.set_vlan_cmd.gsub("NODES", list).gsub("VLAN_ID", @config.exec_specific.vlan).gsub("USER", @config.exec_specific.true_user)
        if (not system(cmd)) then
          @output.verbosel(0, "Cannot set the VLAN")
          @nodes_ok.duplicate_and_free(@nodes_ko)
          return false
        end
      else
        @output.verbosel(3, "  *** Bypass the VLAN setting")
      end
      return true
    end
  end
end
