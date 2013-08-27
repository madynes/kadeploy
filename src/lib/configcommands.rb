require 'config'
require 'configparser'

module Kadeploy

module Configuration
  class CommandsConfig
    include ConfigFile

    def self.file()
      File.join($kadeploy_config_directory, "cmd.yml")
    end

    def load(common)
      configfile = self.class.file
      begin
        config = YAML.load_file(configfile)
      rescue Errno::ENOENT
        return true
      rescue Exception
        $stderr.puts "Invalid YAML file '#{configfile}'"
        return false
      end

      return true unless config

      unless config.is_a?(Hash)
        $stderr.puts "Invalid file format '#{configfile}'"
        return false
      end

      config.each_pair do |nodename,commands|
        node = common.nodes.get_node_by_host(nodename)

        if (node != nil) then
          commands.each_pair do |kind,val|
            if (node.cmd.instance_variable_defined?("@#{kind}")) then
              node.cmd.instance_variable_set("@#{kind}", val)
            else
              $stderr.puts "Unknown command kind: #{kind}"
              return false
            end
          end
        else
          $stderr.puts "The node #{nodename} does not exist"
          return false
        end
      end
    end
  end
end

end

