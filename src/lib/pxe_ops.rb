# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

module PXEOperations
  private
  # Compute the hexalized value of a decimal number
  #
  # Arguments
  # * n: decimal number to hexalize
  # Output
  # * hexalized value of n
  def PXEOperations::hexalize(n)
    return sprintf("%02X", n)
  end

  # Compute the hexalized representation of an IP
  #
  # Arguments
  # * ip: string that contains the ip to hexalize
  # Output
  # * hexalized value of ip
  def PXEOperations::hexalize_ip(ip)
    res = String.new
    ip.split(".").each { |v|
      res.concat(hexalize(v))
    }
    return res
  end
  
  # Write the PXE information related to the group of nodes involved in the deployment
  #
  # Arguments
  # * ips: array of ip (aaa.bbb.ccc.ddd string representation)
  # * msg: string that must be written in the PXE configuration
  # * tftp_repository: absolute path to the TFTP repository
  # * tftp_cfg: relative path to the TFTP configuration repository
  # * singularities: hashtable containing the singularity to be replaced in the pxe profile for each node
  # Output
  # * returns true in case of success, false otherwise
  # Fixme
  # * should do something if the PXE configuration cannot be written
  def PXEOperations::write_pxe(ips, msg, tftp_repository, tftp_cfg, singularities = nil)
    ips.each { |ip|
      msg_dup = msg.dup
      file = File.join(tftp_repository, tftp_cfg, hexalize_ip(ip))
      #prevent from overwriting some linked files
      if File.exist?(file) then
        File.delete(file)
      end
      f = File.new(file, File::CREAT|File::RDWR, 0644)
      if (singularities != nil) then
        msg_dup = msg_dup.gsub("NODE_SINGULARITY", singularities[ip])
      end
      f.write(msg_dup)
      f.close
    }
    return true
  end

  public
  # Modify the PXE configuration for a Linux boot
  #
  # Arguments
  # * ips: array of ip (aaa.bbb.ccc.ddd string representation)
  # * kernel: basename of the vmlinuz file
  # * kernel_params: kernel parameters
  # * initrd: basename of the initrd file
  # * boot_part: path of the boot partition
  # * tftp_repository: absolute path to the TFTP repository
  # * tftp_img: relative path to the TFTP image repository
  # * tftp_cfg: relative path to the TFTP configuration repository
  # * pxe_header: header of the pxe profile
  # Output
  # * returns the value of write_pxe
  def PXEOperations::set_pxe_for_linux(ips, kernel, kernel_params, initrd, boot_part, tftp_repository, tftp_img, tftp_cfg, pxe_header)
    if /\Ahttp[s]?:\/\/.+/ =~ kernel then
      kernel_line = "\tKERNEL " + kernel + "\n" #gpxelinux
    else
      kernel_line = "\tKERNEL " + tftp_img + "/" + kernel + "\n" #pxelinux
    end
    if (initrd != nil) then
      if /\Ahttp[s]?:\/\/.+/ =~ initrd then
        append_line = "\tAPPEND initrd=" + initrd #gpxelinux
      else
        append_line = "\tAPPEND initrd=" + tftp_img + "/" + initrd #pxelinux
      end
    end
    append_line += " root=" + boot_part if (boot_part != "")
    append_line += " " + kernel_params if (kernel_params != "")
    append_line += "\n"
    msg = pxe_header + kernel_line + append_line
    return write_pxe(ips, msg, tftp_repository, tftp_cfg)
  end

  # Modify the PXE configuration for a Xen boot
  #
  # Arguments
  # * ips: array of ip (aaa.bbb.ccc.ddd string representation)
  # * hypervisor: basename of the hypervisor file
  # * hypervisor_params: hypervisor parameters
  # * kernel: basename of the vmlinuz file
  # * kernel_params: kernel parameters
  # * initrd: basename of the initrd file
  # * boot_part: path of the boot partition
  # * tftp_repository: absolute path to the TFTP repository
  # * tftp_img: relative path to the TFTP image repository
  # * tftp_cfg: relative path to the TFTP configuration repository
  # * pxe_header: header of the pxe profile
  # Output
  # * returns the value of write_pxe
  def PXEOperations::set_pxe_for_xen(ips, hypervisor, hypervisor_params, kernel, kernel_params, initrd, boot_part, tftp_repository, tftp_img, tftp_cfg, pxe_header)
    kernel_line = "\tKERNEL " + "mboot.c32\n"
    append_line = "\tAPPEND " + tftp_img + "/" + hypervisor
    append_line +=  " " + hypervisor_params if (hypervisor_params != nil)
    append_line += " --- " + tftp_img + "/" + kernel 
    append_line += " " + kernel_params  if (kernel_params != "")
    append_line += " root=" + boot_part if (boot_part != "")
    append_line += " --- " + tftp_img + "/" + initrd if (initrd != nil)
    append_line += "\n"
    msg = pxe_header + kernel_line + append_line
    return write_pxe(ips, msg, tftp_repository, tftp_cfg)
  end

  # Modify the PXE configuration for a NFSRoot boot
  #
  # Arguments
  # * ips: array of ip (aaa.bbb.ccc.ddd string representation)
  # * nfsroot_kernel: basename of the vmlinuz file
  # * nfsroot_params: append line
  # * tftp_repository: absolute path to the TFTP repository
  # * tftp_img: relative path to the TFTP image repository
  # * tftp_cfg: relative path to the TFTP configuration repository
  # * pxe_header: header of the pxe profile
  # Output
  # * returns the value of write_pxe
  def PXEOperations::set_pxe_for_nfsroot(ips, nfsroot_kernel, nfsroot_params, tftp_repository, tftp_img, tftp_cfg, pxe_header)
    if /\Ahttp[s]?:\/\/.+/ =~ nfsroot_kernel then
      kernel_line = "\tKERNEL " + nfsroot_kernel + "\n" #gpxelinux 
    else
      kernel_line = "\tKERNEL " + tftp_img + "/" + nfsroot_kernel + "\n" #pxelinux
    end
    append_line = "\tAPPEND #{nfsroot_params}\n"
    msg = pxe_header + kernel_line + append_line
    return write_pxe(ips, msg, tftp_repository, tftp_cfg)
  end

  # Modify the PXE configuration for a chainload boot
  #
  # Arguments
  # * ips: array of ip (aaa.bbb.ccc.ddd string representation)
  # * boot_part: number of partition to chainload
  # * tftp_repository: absolute path to the TFTP repository
  # * tftp_img: relative path to the TFTP image repository
  # * tftp_cfg: relative path to the TFTP configuration repository
  # * pxe_header: header of the pxe profile
  # Output
  # * returns the value of write_pxe
  def PXEOperations::set_pxe_for_chainload(ips, boot_part, tftp_repository, tftp_img, tftp_cfg, pxe_header)
    kernel_line = "\tKERNEL " + "chain.c32\n"
    append_line = "\tAPPEND hd0 #{boot_part}\n"
    msg = pxe_header + kernel_line + append_line
    return write_pxe(ips, msg, tftp_repository, tftp_cfg)
  end

  # Modify the PXE configuration for a custom boot
  #
  # Arguments
  # * ips: array of ip (aaa.bbb.ccc.ddd string representation)
  # * msg: custom PXE profile
  # * tftp_repository: absolute path to the TFTP repository
  # * tftp_cfg: relative path to the TFTP configuration repository
  # * singularities: hashtable containing the singularity to be replaced in the pxe profile for each node
  # Output
  # * returns the value of write_pxe
  def PXEOperations::set_pxe_for_custom(ips, msg, tftp_repository, tftp_cfg, singularities)
    return write_pxe(ips, msg, tftp_repository, tftp_cfg, singularities)
  end
end


