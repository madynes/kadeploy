require 'config'
require 'configparser'

module Kadeploy

module Configuration
  class ClusterSpecificConfig

    include ConfigFile

    def self.file()
      File.join($kadeploy_config_directory, "clusters.yml")
    end

    def load(commonconfig)
      configfile = self.class.file
      begin
        begin
          config = YAML.load_file(configfile)
        rescue Errno::ENOENT
          raise ArgumentError.new("File not found '#{configfile}'")
        rescue Exception
          raise ArgumentError.new("Invalid YAML file '#{configfile}'")
        end

        unless config.is_a?(Hash)
          raise ArgumentError.new("Invalid file format'#{configfile}'")
        end

        cp = Parser.new(config)

        cp.parse('clusters',true,Array) do
          clname = cp.value('name',String)

          self[clname] = ClusterSpecificConfig.new.load(clname,clfile)
          return false unless self[clname]
          conf = self[clname]

          clfile = cp.value(
            'conf_file',String,nil,{
              :type => 'file', :readable => true, :prefix => Config.dir()})
          conf.prefix = cp.value('prefix',String,'')

          cp.parse('nodes',true,Array) do |info|
            name = cp.value('name',String)
            address = cp.value('address',String)

            if name =~ Nodes::REGEXP_NODELIST and address =~ Nodes::REGEXP_IPLIST
              hostnames = Nodes::NodeSet::nodes_list_expand(name)
              addresses = Nodes::NodeSet::nodes_list_expand(address)

              if (hostnames.to_a.length == addresses.to_a.length) then
                for i in (0 ... hostnames.to_a.length)
                  tmpname = hostnames[i]
                  common.nodes.push(Nodes::Node.new(
                    tmpname, addresses[i], clname, generate_commands(
                      tmpname, self[clname]
                    )
                  ))
                end
              else
                raise ArgumentError.new(Parser.errmsg(
                    info[:path],"Incoherent number of hostnames and IP addresses"
                  )
                )
              end
            else
              begin
                common.nodes.push(Nodes::Node.new(
                    name,
                    address,
                    clname,
                    generate_commands(name, self[clname])
                ))
              rescue ArgumentError
                raise ArgumentError.new(Parser.errmsg(
                    info[:path],"Invalid address"
                  )
                )
              end
            end
          end
        end
      rescue ArgumentError => ae
        $stderr.puts ''
        $stderr.puts "Error(#{configfile}) #{ae.message}"
        return false
      end

      if common.nodes.empty? then
        puts "The nodes list is empty"
        return false
      else
        return true
      end
    end

    def generate_commands(hostname, cluster)
      cmd = Nodes::NodeCmd.new
      if cluster then
        cmd.reboot_soft = replace_hostname(cluster.cmd_soft_reboot, hostname)
        cmd.reboot_hard = replace_hostname(cluster.cmd_hard_reboot, hostname)
        cmd.reboot_very_hard = replace_hostname(cluster.cmd_very_hard_reboot, hostname)
        cmd.console = replace_hostname(cluster.cmd_console, hostname)
        cmd.power_on_soft = replace_hostname(cluster.cmd_soft_power_on, hostname)
        cmd.power_on_hard = replace_hostname(cluster.cmd_hard_power_on, hostname)
        cmd.power_on_very_hard = replace_hostname(cluster.cmd_very_hard_power_on, hostname)
        cmd.power_off_soft = replace_hostname(cluster.cmd_soft_power_off, hostname)
        cmd.power_off_hard = replace_hostname(cluster.cmd_hard_power_off, hostname)
        cmd.power_off_very_hard = replace_hostname(cluster.cmd_very_hard_power_off, hostname)
        cmd.power_status = replace_hostname(cluster.cmd_power_status, hostname)
        return cmd
      else
        $stderr.puts "Missing specific config file for the cluster #{cluster}"
        raise
      end
    end

    # Replace the substrings HOSTNAME_FQDN and HOSTNAME_SHORT in a string by a value
    #
    # Arguments
    # * str: string in which the HOSTNAME_FQDN and HOSTNAME_SHORT values must be replaced
    # * hostname: value used for the replacement
    # Output
    # * return the new string       
    def replace_hostname(str, hostname)
      if (str != nil) then
        cmd_to_expand = str.clone # we must use this temporary variable since sub() modify the strings
        save = str
        while cmd_to_expand.sub!("HOSTNAME_FQDN", hostname) != nil  do
          save = cmd_to_expand
        end
        while cmd_to_expand.sub!("HOSTNAME_SHORT", hostname.split(".")[0]) != nil  do
          save = cmd_to_expand
        end
        return save
      else
        return nil
      end
    end
  end
end

end
