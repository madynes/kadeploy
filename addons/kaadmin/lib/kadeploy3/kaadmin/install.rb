
require 'optparse'
require 'open-uri'
require 'yaml'
require 'tempfile'
# set old yameler
YAML::ENGINE.yamler = 'syck'


module Kadeploy
  module Kaadmin

    #TODO : find system buffer size.
    BUFFER_SIZE=64*1024
    BUFFER_SIZE_LOCAL=8*1024*1024


    #Simple progress indicator
    class ProgressBar
      def initialize(max)
        @max=max
        @cur=0
        @last_display=0
        @step = max/100
        @step = 1 if @step==0
        if max > 0
          $stdout.write('  0 %')
        else
          $stdout.write('   0  B read')
        end
        $stdout.flush
      end
      def add(add)
        step(@cur+=add)
      end
      def step(step)
        @cur=step
        if @max > 0
          if @last_display+@step < @cur
            count=(@cur*100/@max).to_s
            @last_display=@cur
            $stdout.write("\r#{count.rjust(3)} %")
            $stdout.flush
          end
        else
          $stdout.write("\r#{cur.to_human.rjust(4)} read")
          $stdout.flush
        end
      end
    end


    class Numeric
      def to_human
        units = ['  B',' KB',' MB', ' GB',' TB']
        e = (Math.log(self)/Math.log(1024)).floor
        s = "%.3f" % (to_f / 1024**e)
        s.sub(/\.?0*$/, units[e])
      end
    end



    class Install
      def self.ask(question,default=nil)
        resp=nil
        begin
          $stdout.flush
          $stdout.write("#{question} #{default ? "[#{default}]":''}")
          $stdout.flush
          resp=$stdin.readline.strip
          resp= resp=='' ? default : resp
        end until (resp)
        resp
      end
      def self.ask_yes_no(question,default='')
        d=['y','n']
        i = d.index(default)
        dd=d.clone
        dd[i] = d[i].upcase if i
        default = "#{dd[0]}|#{dd[1]}"
        begin
            resp = ask(question,default).downcase
        end while (i && i<0 && default == resp)
        return i==0 if resp==default.downcase
        d.index(resp) == 0
      end


      def self.chown(file)
        #I'm lazy, I don't want looking for user id.
        system("chown #{$user} #{file}")
      end

      def self.cp(src,dst,umask=0022)
      # FileUtils.mkdir_p
        dir=File.dirname(dst)
        if File.directory?dir
          while File.exists?(dst)
            if ask_yes_no("#{dst} is already existing, would you update it ?",'n')
              break
            else
              dst= ask("Enter new name",dst+'.new')
            end
          end
          else
          if ask_yes_no("#{dir} does not existing, would you create it ?",'y')
            list_dir=FileUtils.mkdir_p(dir,{:mode=>(0755&~umask)})
            list_dir.each do |c_dir|
              chown(c_dir)
            end
          else
            raise "output directory does not exists"
          end
        end
        puts "copy from '#{src}' to '#{dst}'"
        pg = nil
        File.open(dst,'w') do |write_file|
          open(src,content_length_proc: proc { |total| pg = ProgressBar.new(total)},progress_proc: proc { |step| pg.step(step)},redirect: true) do |read_file|
            until(read_file.eof?)
              buffer=read_file.read(BUFFER_SIZE_LOCAL)
              write_file.write(buffer)
            end
          end
        end
        File.chmod(0644&~umask,dst)
        chown(dst)
        $stdout.puts("\r100 %")
        $stdout.flush
        dst
      end

      def self.load_from_yaml(src)
        obj=nil
        open(src) do |file|
          obj=YAML.load(file.read)
        end
        obj
      end

      def self.install_file (src,local_path,dist_prefix,umask=0022,file_dest=nil)
        origin=File.basename(src)
        dist_prefix=File.dirname(src) if src.include?("/")
        final_dest=cp(File.join(dist_prefix,origin),File.join(local_path,file_dest ? file_dest : origin))
        "server://#{final_dest}"
      end

      def self.get_param(conf,path)
        path.split('/').each do |elem|
          conf=conf[elem]
          break unless conf
        end
        conf
      end
      def self.launch(argv)
        if (ENV['USER'] != 'root')
          $stderr.puts('This program must be launch with root rights')
          exit(-1)
        end

        $kadeploy_confdir=ENV['KADEPLOY3_CONFIG_DIR']||'/etc/kadeploy3'
        $kadeploy_conf_server=File.join($kadeploy_confdir,'server_conf.yml')
        $user='deploy'


        yaml_url = nil
        # Parse options
        opt=OptionParser.new do |opts|
          opts.banner = "Usage: #{$0} [options] install_URI"
          opts.separator 'General options:'
          opts.on("-c", "--conf-file FILE") do |file|
            $kadeploy_conf_server=file
          end
          opts.on("-v", "--version", "show the version") do |p|
            puts 'Kaadmin3: Image installer version 0.1'
            exit
          end
          opts.on("-D", "--[no-]debug", "set debugging flags (set $DEBUG to true)") do |d|
            $DEBUG=d
          end
          opts.on_tail('-?', '--help', 'show this message') do
            puts opts
            exit
          end
        end
        list=opt.parse!(argv)
        yaml_url=list[0]

        $stderr.puts "Warning : the follows arguments are not used #{list.join(' ')}" unless list.empty?
        if yaml_url == nil
          $stderr.puts('URI is missing')
          $stderr.puts(opt)
          exit(-1)
        end


        begin
          unless File.exists?($kadeploy_conf_server)
            $stderr.puts("#{$kadeploy_conf_server} does not existing, quit...")
          end
          config = load_from_yaml($kadeploy_conf_server)
          puts 'Loading yaml file ...'
          img_conf=load_from_yaml(yaml_url)
          raise "#{yaml_url} is not correct description file" unless img_conf.is_a? Hash
          dist_path = File.dirname(yaml_url)
          puts ''
          puts "name        : #{img_conf['name']}"
          puts "description : #{img_conf['description']}"
          puts "author      : #{img_conf['author']}"
          puts "System type : #{img_conf['os']}"
          if img_conf['os']=='deploy'
            # TODO : get confirmation from user ?
            puts "private key : #{img_conf['private_key'].nil? ? 'no':'yes'}"
            puts ''
            image_path = File.join(get_param(config,'pxe/dhcp/repository'),'kernels')
            image_path = ask('Enter the destination folder',image_path)
            #TODO : use cluster configuration to propose different destination of deploy kernel
            [img_conf['vmlinuz'],img_conf['initrd']].each do |file|
              install_file(file,image_path,dist_path)
            end
            key_path=get_param(config,'security/ssh_private_key')
            install_file(img_conf['private_key'],File.dirname(key_path),dist_path,0077,File.basename(key_path))
          else
            puts ''
            image_path=get_param(config,'local_images_path') || '/var/lib/kadeploy3/images'

            image_path = ask('Enter the destination folder',image_path)
            img_conf['image']['file'] = install_file(img_conf['image']['file'],image_path,dist_path)
            img_conf['preinstall']['archive'] = install_file(img_conf['preinstall']['archive'],image_path,dist_path) if img_conf['preinstall']

            if img_conf['postinstalls']
              postinstalls.collect do |postinstall|
                postinstall['archive'] = install_file(postinstall['archive'],image_path,dist_path)
              end
            end

            file = Tempfile.new('tmpyaml')
            file.write(img_conf.to_yaml)
            file.close
            system("kaenv3 -a #{file.path}")
            unless $?.success?
              $stderr.puts "The command kaenv ('kaenv3 -a file.yaml') has reported an error. The configuration file:"
              $stderr.puts img_conf.to_yaml
            end
          end
        rescue Exception => ex
          $stderr.puts(ex)
          $stderr.puts(ex.backtrace) if $DEBUG
        end
      end
    end
  end
end
