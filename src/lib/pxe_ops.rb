# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
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
  # Output
  # * returns true in case of success, false otherwise
  # Fixme
  # * should do something if the PXE configuration cannot be written
  def PXEOperations::write_pxe(ips, msg, tftp_repository, tftp_cfg)
    ips.each { |ip|
      file = tftp_repository + "/" + tftp_cfg + "/" + hexalize_ip(ip)
      #prevent from overwriting some linked files
      if File.exist?(file) then
        File.delete(file)
      end
      f = File.new(file, File::CREAT|File::RDWR, 0644)
      f.write(msg)
      f.close
    }
    return true
  end
  
  def PXEOperations::get_pxe_header()
    prompt = 1
    display = "messages"
    timeout = 50
    baudrate = 38400
    return "PROMPT #{prompt}\nSERIAL 0 #{baudrate}\nDEFAULT bootlabel\nDISPLAY #{display}\nTIMEOUT #{timeout}\n\nlabel bootlabel\n";
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
  # Output
  # * returns the value of write_pxe
  def PXEOperations::set_pxe_for_linux(ips, kernel, kernel_params, initrd, boot_part, tftp_repository, tftp_img, tftp_cfg)
    if /\Ahttp:\/\/.+/ =~ kernel then
      kernel_line = "\tKERNEL " + kernel + "\n" #gpxelinux
    else
      kernel_line = "\tKERNEL " + tftp_img + "/" + kernel + "\n" #pxelinux
    end
    if /\Ahttp:\/\/.+/ =~ initrd then
      append_line = "\tAPPEND initrd=" + initrd #gpxelinux
    else
      append_line = "\tAPPEND initrd=" + tftp_img + "/" + initrd #pxelinux
    end
    if (boot_part != "")
      append_line += " root=" + boot_part + " " + kernel_params
    else
      append_line += " " + kernel_params
    end
    append_line += "\n"
    msg = get_pxe_header() + kernel_line + append_line
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
  # Output
  # * returns the value of write_pxe
  def PXEOperations::set_pxe_for_xen(ips, hypervisor, hypervisor_params, kernel, kernel_params, initrd, boot_part, tftp_repository, tftp_img, tftp_cfg)
    kernel_line = "\tKERNEL " + tftp_img + "/mboot.c32\n"
    append_line = "\tAPPEND " + tftp_img + "/" + hypervisor + " " + hypervisor_params 
    append_line += " --- " + tftp_img + "/" + kernel + " " + kernel_params
    append_line += " root=" + boot_part if (boot_part != "")
    append_line += " --- " + tftp_img + "/" + initrd
    append_line += "\n"
    msg = get_pxe_header() + kernel_line + append_line
    return write_pxe(ips, msg, tftp_repository, tftp_cfg)
  end

  # Modify the PXE configuration for a NFSRoot boot
  #
  # Arguments
  # * ips: array of ip (aaa.bbb.ccc.ddd string representation)
  # * kernel: basename of the vmlinuz file
  # * nfs_server: ip of the NFS server
  # * tftp_repository: absolute path to the TFTP repository
  # * tftp_img: relative path to the TFTP image repository
  # * tftp_cfg: relative path to the TFTP configuration repository
  # Output
  # * returns the value of write_pxe
  def PXEOperations::set_pxe_for_nfsroot(ips, kernel, nfs_server, tftp_repository, tftp_img, tftp_cfg)
    if /\Ahttp:\/\/.+/ =~ kernel then
      kernel_line = "\tKERNEL " + kernel + "\n" #gpxelinux 
    else
      kernel_line = "\tKERNEL " + tftp_img + "/" + kernel + "\n" #pxelinux
    end
    append_line = "\tAPPEND rw console=ttyS0,115200n81 console=tty0 root=/dev/nfs ip=dhcp nfsroot=#{nfs_server}:#{nfs_root_path}\n"
    msg = get_pxe_header() + kernel_line + append_line
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
  # Output
  # * returns the value of write_pxe
  def PXEOperations::set_pxe_for_chainload(ips, boot_part, tftp_repository, tftp_img, tftp_cfg)
    kernel_line = "\tKERNEL " + tftp_img + "/chain.c32\n"
    append_line = "\tAPPEND hd0 #{boot_part}\n"
    msg = get_pxe_header() + kernel_line + append_line
    return write_pxe(ips, msg, tftp_repository, tftp_cfg)
  end

  # Modify the PXE configuration for a custom boot
  #
  # Arguments
  # * ips: array of ip (aaa.bbb.ccc.ddd string representation)
  # * msg: custom PXE profile
  # * tftp_repository: absolute path to the TFTP repository
  # * tftp_cfg: relative path to the TFTP configuration repository
  # Output
  # * returns the value of write_pxe
  def PXEOperations::set_pxe_for_custom(ips, msg, tftp_repository, tftp_cfg)
    return write_pxe(ips, msg, tftp_repository, tftp_cfg)
  end
end


