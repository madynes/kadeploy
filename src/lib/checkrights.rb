# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt


module CheckRights
  
  USER = `id -nu`.chomp

  class CheckRightsFactory
    
    # Factory for the methods to check the rights
    #
    # Arguments
    # * kind: specifies the method to use
    # * node_list(opt): instance of NodeSet that contains the nodes on which the rights must be checked
    # * part(opt): string that specifies the partition on which the rights must be checked
    # Output
    # * returns a Check instance (CheckDummy or CheckInDB)
    def CheckRightsFactory.create(kind, node_list = nil, db = nil, part = nil)
      case kind
      when "dummy"
        return CheckDummy.new
      when "db"
        return CheckInDB.new(node_list, db, part)
      else
        raise "Invalid kind of rights check"
      end
    end
  end

  class Check
    @granted = nil
    
    # Constructor of Check
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def initialize
      @granted = false
    end

    # Check if the rights are granted
    #
    # Arguments
    # * nothing
    # Output
    # * returns true if the rights are granted, false otherwise
    def granted?
      return @granted
    end
  end

  class CheckDummy < Check

    # Constructor of CheckDummy
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def initialize
      @granted = true
    end
  end

  class CheckInDB < Check
    @db = nil
    @host_list = nil
    @part = nil

    # Constructor of CheckInDB
    #
    # Arguments
    # * node_list: NodeSet involved in the deployment
    # * db: database handler
    # * part: partition required for the deployment
    # Output
    # * nothing
    def initialize(node_list, db, part)
      @host_list = node_list.make_array_of_hostname
      @db = db
      @part = part
      @granted = false
    end

    # Check if the rights are granted
    #
    # Arguments
    # * nothing
    # Output
    # * returns true if the rights are granted, false otherwise
    def granted?
      query = "SELECT * FROM rights WHERE user=\"#{USER}\" AND (part=\"#{@part}\" OR part=\"*\")"
      @host_list.each { |host|
        node_found = false
        res = @db.run_query(query)
        if res != nil then
          while ((node_found == false) && (hash = res.fetch_hash)) do
            if ((hash["node"] == host) || (hash["node"] == "*")) then
              node_found = true
            end
          end
        end
        if (node_found == false) then
          puts "You do not have the rights to deploy on the node #{host}:#{@part}"
          return false
        end
      }
      return true
    end
  end
end
