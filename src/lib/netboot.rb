
module NetBoot
  def self.Factory(kind, binary, export_kind, export_server, repository_dir, profiles_dir, profiles_kind, chain=nil)
    begin
      c = NetBoot.class_eval(kind)
    rescue NameError
      raise "Invalid kind of PXE configuration"
    end

    c.new(
      binary,
      c::Export.new(export_kind,export_server),
      repository_dir,
      profiles_dir,
      profiles_kind,
      chain
    )
  end

  class NetBoot::Exception < Exception
  end

  class PXE
    class Export
      def initialize(kind, server)
        raise NetBoot::Exception.new("#{self.class.name} do not support '#{kind.to_s}' (supported values: #{kinds().join(', ')})") unless kinds().include?(kind)
        @kind = kind
        @server = server
      end

      def kinds()
        raise 'Should be reimplemented'
      end

      def path(path)
        raise 'Should be reimplemented'
      end
    end

    attr_reader :binary
    attr_reader :export
    attr_reader :chain

    def initialize(binary, export, repository_dir, profiles_dir, profiles_kind, chain=nil)
      @binary = binary
      @export = export
      @repository_dir = repository_dir
      @profiles_dir = profiles_dir
      @profiles_kind = "profilename_#{profiles_kind}".to_sym
      @chain = chain
    end

    def boot(kind,nodes,headers,*args)
      if @chain and (@chain.class != self.class or @chain.binary != @binary)
        @chain.boot(:chain,nodes,headers,@binary)
      end

      profile, meth = send("boot_#{kind.to_s}".to_sym,*args)

      profile = "#{headers[kind]}#{labelize(kind.to_s,profile,args)}\n" \
        unless kind == :custom

      write_profile(nodes,profile,meth)
    end

    protected
    def labelize(kind,profile,args)
      raise 'Should be reimplemented'
    end

    def boot_chain(pxebin)
      raise 'Should be reimplemented'
    end

    def boot_local(env, diskname, device_id, partition_id)
      raise 'Should be reimplemented'
    end

    def boot_network(kernel, initrd, params)
      raise 'Should be reimplemented'
    end

    def boot_custom(profile, user=nil, singularities=nil)
      [
        profile,
        lambda do |prof,node|
          prof.gsub!("PXE_EXPORT",export_path(nil))
          prof.gsub!("NODE_SINGULARITY",singularities[node[:hostname]].to_s) if singularities
          prof.gsub!("FILES_PREFIX","pxe-#{user}") if user
          prof
        end
      ]
    end

    def export_path(path)
      @export.path(path)
    end

    private
    def profilename_hostname(node)
      node[:hostname]
    end

    def profilename_hostname_short(node)
      node[:hostname].split('.')[0]
    end

    def profilename_ip(node)
      node[:ip].strip
    end

    def profilename_ip_hex(node)
      node[:ip].split(".").collect{ |n| sprintf("%02X", n) }.join('')
    end

    def profile_dir(node)
      File.join(@repository_dir,@profiles_dir,send(@profiles_kind, node))
    end

    def write_profile(nodes, profile, meth=nil)
      prof = profile
      nodes.each do |node|
        file = profile_dir(node)
        File.delete(file) if File.exist?(file)
        begin
          f = File.new(file, File::CREAT|File::RDWR, 0644)
          prof = meth.call(profile.dup,node) if meth
          f.write(prof)
          f.close
        rescue
          return false
        end
      end
      true
    end
  end

  class PXElinux < PXE
    class Export < PXE::Export
      def kinds()
        [
          :tftp
        ]
      end

      def path(path)
        if path
          File.join('/',path)
        else
          ''
        end
      end
    end

    def labelize(kind,profile,args=[])
      "LABEL #{kind}\n"\
      + profile.collect{|line| "\t#{line}"}.join("\n")
    end

    def boot_chain(pxebin)
      [[
        "KERNEL #{export_path(pxebin)}"
      ]]
    end

    def boot_local(env, diskname, device_id, partition_id)
      [[
        "COM32 #{export_path('chain.c32')}",
        "APPEND hd#{device_id} #{partition_id}",
      ]]
    end

    def boot_network(kernel, initrd, params)
      profile = []

      profile << "KERNEL #{export_path(kernel)} #{params}"
      profile << "APPEND initrd=#{export_path(initrd)}" if initrd

      [ profile ]
    end
  end

  class GPXElinux < PXElinux
    class Export < PXE::Export
      def kinds()
        [
          :tftp,
          :http,
          :ftp,
        ]
      end

      def path(path)
        case @kind
        when :tftp
          if path
            File.join('/',path)
          else
            ''
          end
        when :http,:tftp
          if path
            File.join("#{@kind.to_s}://",@server,path)
          else
            File.join("#{@kind.to_s}://",@server)
          end
        end
      end
    end

  end

  class IPXE < PXE
    class Export < PXE::Export
      def kinds()
        [
          :tftp,
          :http,
          :ftp,
        ]
      end

      def path(path)
        case @kind
        when :tftp
          if path
            File.join('/',path)
          else
            ''
          end
        when :http,:tftp
          if path
            File.join("#{@kind.to_s}://",@server,path)
          else
            File.join("#{@kind.to_s}://",@server)
          end
        end
      end
    end

    def labelize(kind,profile,args=[])
      "#!ipxe\n#{profile.join("\n")}"
    end

    def boot_chain(pxebin)
      [[
        "chain #{export_path(pxebin)}",
      ]]
    end

    def boot_local(env, diskname, device_id, partition_id)
      [[
        "chain #{export_path('chain.c32')} hd#{device_id} #{partition_id}",
      ]]
    end

    def boot_network(kernel, initrd, params)
      profile = []

      profile << "initrd #{export_path(initrd)}" if initrd
      profile << "chain #{export_path(kernel)} #{params}"

      [ profile ]
    end
  end

  class GrubPXE < PXE
    class Export < PXE::Export
      def kinds()
        [
          :tftp,
        ]
      end

      def path(path)
        case @kind
        when :tftp
          if path
            File.join('(pxe)',path)
          else
            '(pxe)'
          end
        end
      end
    end

    def labelize(kind,profile,args=[])
      profile = profile.collect{|line| "\t#{line}"}.join("\n")
      [
        'set default=1',
        'set timeout=0',
        '',
        "menuentry #{kind} {",
        profile,
        '}'
      ].join("\n")
    end

    def boot_chain(pxebin)
      [[
        "pxechainloader #{export_path(pxebin)}",
      ]]
    end

    def boot_local(env, diskname, device_id, partition_id)
      profile = [ "set root=(hd#{device_id},#{partition_id})" ]

      partname = "#{diskname}#{partition_id}"

      case env.environment_kind
      when 'linux'
        profile << "linux #{env.kernel} #{env.kernel_params} root=#{partname}"
        profile << "initrd #{env.initrd}" if env.initrd and !env.initrd.empty?
      when 'xen'
        profile << "multiboot #{env.hypervisor} #{env.hypervisor_params}"
        profile << "module #{env.kernel} #{env.kernel_params} root=#{partname}"
        profile << "initrd #{env.initrd}" if env.initrd and !env.initrd.empty?
      when 'bsd'
        profile << "insmod ufs1"
        profile << "insmod ufs2"
        profile << "insmod zfs"
        profile << "chainloader +1"
      when 'windows'
        profile << "insmod fat"
        profile << "insmod ntfs"
        profile << "ntldr /bootmgr"
      when 'other'
        profile << "chainloader +1"
      end

      [ profile ]
    end

    def boot_network(kernel, initrd, params)
      profile = []

      profile << "kernel #{export_path(kernel)} #{params}"
      profile << "initrd #{export_path(initrd)}" if initrd

      [ profile ]
    end
  end
end
