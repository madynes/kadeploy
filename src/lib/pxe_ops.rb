# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2012
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

IPXEHEADER = "#!gpxe\n"

module PXEOperations
  def PXEOperations::PXEFactory(kind, pxe_repository, pxe_repository_kernels, pxe_export)
    begin
      c = PXEOperations::class_eval(kind)
    rescue NameError
      raise "Invalid kind of PXE configuration"
    end
    return c.new(pxe_repository, pxe_repository_kernels, pxe_export)
  end

  class PXE
    attr_reader :pxe_repository_kernels
    attr_reader :pxe_repository

    @pxe_repository = nil
    @pxe_export = nil
    @pxe_repository_kernels = nil

    def initialize(pxe_repository, pxe_repository_kernels, pxe_export)
      @pxe_repository = pxe_repository
      @pxe_export = pxe_export
      @pxe_repository_kernels = pxe_repository_kernels
    end

    def kernel_path
      File.join(@pxe_export,@pxe_repository_kernels)
    end

    private
    
    # Compute the hexalized value of a decimal number
    #
    # Arguments
    # * n: decimal number to hexalize
    # Output
    # * hexalized value of n
    def hexalize(n)
      return sprintf("%02X", n)
    end
    
    # Compute the hexalized representation of an IP
    #
    # Arguments
    # * ip: string that contains the ip to hexalize
    # Output
    # * hexalized value of ip
    def hexalize_ip(ip)
      res = String.new
      ip.split(".").each { |v|
        res.concat(hexalize(v))
      }
      return res
    end

    # Write the PXE information related to the group of nodes involved in the deployment
    #
    # Arguments
    # * nodes_if: array of { 'ip' => ip, 'dest' => dest}
    # * msg: string that must be written in the PXE configuration
    # * singularities: hashtable containing the singularity to be replaced in the pxe profile for each node
    # Output
    # * returns true in case of success, false otherwise
    # Fixme
    # * should do something if the PXE configuration cannot be written
    def write_pxe(nodes_info, msg, singularities = nil, username = nil)
      nodes_info.each { |node|
        msg_dup = msg.dup

        msg_dup.gsub!("KERNELS_DIR", kernel_path())
        msg_dup.gsub!("NODE_SINGULARITY", singularities[node['ip']]) if singularities
        msg_dup.gsub!("FILES_PREFIX", "pxe-#{username}") if username

        file = node['dest']
        #prevent from overwriting some linked files
        if File.exist?(file) then
          File.delete(file)
        end
        begin
          f = File.new(file, File::CREAT|File::RDWR, 0644)
          f.write(msg_dup)
          f.close
        rescue
          return false
        end
      }
      return true
    end
    
    # Modify the PXE configuration for a Linux boot
    #
    # Arguments
    # * nodes: Array of {'hostname' => h, 'ip'=> ip }
    # * kernel: basename of the vmlinuz file
    # * kernel_params: kernel parameters
    # * initrd: basename of the initrd file
    # * boot_part: path of the boot partition
    # * pxe_header: header of the pxe profile
    # Output
    # * returns the value of write_pxe
    def set_pxe_for_linux(nodes, kernel, kernel_params, initrd, boot_part, pxe_header)
    end

    # Modify the PXE configuration for a Linux boot
    #
    # Arguments
    # * nodes: Array of {'hostname' => h, 'ip'=> ip }
    # * kernel: basename of the vmlinuz file
    # * kernel_params: kernel parameters
    # * initrd: basename of the initrd file
    # * boot_part: path of the boot partition
    # * pxe_header: header of the pxe profile
    # Output
    # * returns the value of write_pxe
    def set_pxe_for_xen(nodes, hypervisor, hypervisor_params, kernel, kernel_params, initrd, boot_part, pxe_header)
    end

    # Modify the PXE configuration for a NFSRoot boot
    #
    # Arguments
    # * nodes: Array of {'hostname' => h, 'ip'=> ip }
    # * nfsroot_kernel: basename of the vmlinuz file
    # * nfsroot_params: append line
    # * pxe_header: header of the pxe profile
    # Output
    # * returns the value of write_pxe
    def set_pxe_for_nfsroot(nodes, nfsroot_kernel, nfsroot_params, pxe_header)
    end

    # Modify the PXE configuration for a chainload boot
    #
    # Arguments
    # * nodes: Array of {'hostname' => h, 'ip'=> ip }
    # * boot_part: number of partition to chainload
    # * pxe_header: header of the pxe profile
    # Output
    # * returns the value of write_pxe
    def set_pxe_for_chainload(nodes, boot_part, pxe_header)
    end

    # Modify the PXE configuration for a custom boot
    #
    # Arguments
    # * nodes: Array of {'hostname' => h, 'ip'=> ip }
    # * msg: custom PXE profile
    # * singularities: hashtable containing the singularity to be replaced in the pxe profile for each node
    # Output
    # * returns the value of write_pxe
    def set_pxe_for_custom(nodes, msg, singularities, username)
    end
  end

  class PXElinux < PXE
    def set_pxe_for_linux(nodes, kernel, kernel_params, initrd, boot_part, pxe_header)
      kernel_line = "\tKERNEL #{File.join(kernel_path(),kernel)}\n"
      append_line = "\tAPPEND initrd=#{File.join(kernel_path(),initrd)}" if (initrd != nil)
      append_line += " root=" + boot_part if (boot_part != "")
      append_line += " " + kernel_params if (kernel_params != "")
      append_line += "\n"

      msg = pxe_header + kernel_line + append_line
      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_xen(nodes, hypervisor, hypervisor_params, kernel, kernel_params, initrd, boot_part, pxe_header)
      kernel_line = "\tKERNEL mboot.c32\n"
      append_line = "\tAPPEND #{File.join(kernel_path(),hypervisor)}"
      append_line +=  " " + hypervisor_params if (hypervisor_params != nil)
      append_line += " --- #{File.join(kernel_path(),kernel)}"
      append_line += " " + kernel_params  if (kernel_params != "")
      append_line += " root=" + boot_part if (boot_part != "")
      append_line += " --- #{File.join(kernel_path(),initrd)}" if (initrd != nil)
      append_line += "\n"
      msg = pxe_header + kernel_line + append_line

      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_nfsroot(nodes, nfsroot_kernel, nfsroot_params, pxe_header)
      kernel_line = "\tKERNEL #{File.join(kernel_path(),nfsroot_kernel)}\n"
      append_line = "\tAPPEND #{nfsroot_params}\n"
      msg = pxe_header + kernel_line + append_line

      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_chainload(nodes, boot_part, pxe_header)
      kernel_line = "\tKERNEL chain.c32\n"
      append_line = "\tAPPEND hd0 #{boot_part}\n"
      msg = pxe_header + kernel_line + append_line

      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_custom(nodes, msg, singularities,username)
      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return write_pxe(nodes_info, msg, singularities, username)
    end
  end

  class GPXElinux < PXE
    def set_pxe_for_linux(nodes, kernel, kernel_params, initrd, boot_part, pxe_header)
      kernel_line = "\tKERNEL #{File.join(kernel_path(),kernel)}\n"
      append_line = "\tAPPEND initrd=#{File.join(kernel_path(),initrd)}" if (initrd != nil)
      append_line += " root=" + boot_part if (boot_part != "")
      append_line += " " + kernel_params if (kernel_params != "")
      append_line += "\n"
      msg = pxe_header + kernel_line + append_line

      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_xen(nodes, hypervisor, hypervisor_params, kernel, kernel_params, initrd, boot_part, pxe_header)
      kernel_line = "\tKERNEL #{File.join(@pxe_export,'mboot.c32')}\n"
      append_line = "\tAPPEND #{File.join(kernel_path(),hypervisor)}"
      append_line +=  " " + hypervisor_params if (hypervisor_params != nil)
      append_line += " --- #{File.join(kernel_path(),kernel)}"
      append_line += " " + kernel_params  if (kernel_params != "")
      append_line += " root=" + boot_part if (boot_part != "")
      append_line += " --- #{File.join(kernel_path(),initrd)}" if (initrd != nil)
      append_line += "\n"
      msg = pxe_header + kernel_line + append_line

      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_nfsroot(nodes, nfsroot_kernel, nfsroot_params, pxe_header)
      kernel_line = "\tKERNEL #{File.join(kernel_path(),nfsroot_kernel)}\n"
      append_line = "\tAPPEND #{nfsroot_params}\n"
      msg = pxe_header + kernel_line + append_line

      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_chainload(nodes, boot_part, pxe_header)
      kernel_line = "\tKERNEL #{File.join(@pxe_export,'chain.c32')}\n"
      append_line = "\tAPPEND hd0 #{boot_part}\n"
      msg = pxe_header + kernel_line + append_line

      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_custom(nodes, msg, singularities, username)
      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return write_pxe(nodes_info, msg, singularities, username)
    end

  end

  class IPXE < PXE
    def set_pxe_for_linux(nodes, kernel, kernel_params, initrd, boot_part, pxe_header)
      kernel_line = "kernel #{File.join(kernel_path(),kernel)} #{kernel_params}"
      kernel_line += " root=" + boot_part if (boot_part != "")
      kernel_line += "\n"
      append_line = "initrd #{File.join(kernel_path(),initrd)}" if (initrd != nil)
      msg = IPXEHEADER + kernel_line + append_line + "\nboot\n"

      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, node['hostname']) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_xen(nodes, hypervisor, hypervisor_params, kernel, kernel_params, initrd, boot_part, pxe_header)
      kernel_line = "\tKERNEL mboot.c32\n"
      append_line = "\tAPPEND #{File.join(kernel_path(),hypervisor)}"
      append_line +=  " " + hypervisor_params if (hypervisor_params != nil)
      append_line += " --- #{File.join(kernel_path(),kernel)}"
      append_line += " " + kernel_params  if (kernel_params != "")
      append_line += " root=" + boot_part if (boot_part != "")
      append_line += " --- #{File.join(kernel_path(),initrd)}" if (initrd != nil)
      append_line += "\n"
      msg = pxe_header + kernel_line + append_line

      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return false if not write_pxe(nodes_info, msg)

      msg = "#{IPXEHEADER}chain pxelinux.0\nboot\n"
      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, node['hostname']) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_nfsroot(nodes, nfsroot_kernel, nfsroot_params, pxe_header)
      kernel_line = "kernel #{File.join(kernel_path(),nfsroot_kernel)} #{nfsroot_params}"
      msg = pxe_header + kernel_line + "\nboot\n"

      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_chainload(nodes, boot_part, pxe_header)
      kernel_line = "\tKERNEL #{File.join(@pxe_export,'chain.c32')}\n"
      append_line = "\tAPPEND hd0 #{boot_part}\n"
      msg = pxe_header + kernel_line + append_line

      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }
      return false if not write_pxe(nodes_info, msg)

      msg = "#{IPXEHEADER}chain pxelinux.0\nboot\n"
      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, node['hostname']) }
      }
      return write_pxe(nodes_info, msg)
    end

    def set_pxe_for_custom(nodes, msg, singularities, username)
      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, 'pxelinux.cfg', hexalize_ip(node['ip'])) }
      }

      return false if not write_pxe(nodes_info, msg, singularities, username)

      msg = "#{IPXEHEADER}chain pxelinux.0\nboot\n"
      nodes_info = nodes.collect { |node|
        { 'ip' => node['ip'], 'dest' => File.join(@pxe_repository, node['hostname']) }
      }
      return write_pxe(nodes_info, msg)
    end
  end
end

