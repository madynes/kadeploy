# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Ruby libs
require 'mysql'

module Database
  class DbFactory

    # Factory for the methods to access the database
    #
    # Arguments
    # * kind: specifies the kind of database to use (currently, only mysql is supported)
    # Output
    # * return a Db instance
    def DbFactory.create(kind)
      case kind
      when "mysql"
        return DbMysql.new
      else
        raise "Invalid kind of database"
      end
    end
  end
  
  class Db
    attr_accessor :dbh

    #Constructor of Db
    #
    # Arguments
    # * nothing
    # Output
    # * nothing    
    def initialize
      @dbh = nil
    end

    # Abstract method to connect to the database
    #
    # Arguments
    # * host: hostname
    # * user: user granted to access the database
    # * passwd: user's password
    # * base: database name
    # Output
    # * nothing
    def connect(host, user, passwd, base)
    end

    # Abstract method to disconnect from the database
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def disconnect
    end

    # Abstract method to run a query
    #
    # Arguments
    # * query: string that contains the sql query
    # Output
    # * nothing
    def run_query(query)
    end

    # Abstract method to get the number of affected rows
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def get_nb_affected_rows
    end
  end

  class DbMysql < Db

    # Connect to the MySQL database
    #
    # Arguments
    # * host: hostname
    # * user: user granted to access the database
    # * passwd: user's password
    # * base: database name
    # Output
    # * return true if the connection has been established, false otherwise
    # * print an error if the connection can not be performed, otherwhise assigns a database handler to @dhb
    def connect(host, user, passwd, base)
      ret = true
      begin
        @dbh = Mysql.real_connect(host, user, passwd, base)
        @dbh.reconnect = true
      rescue Mysql::Error => e
        puts "Error code: #{e.errno}"
        puts "Error message: #{e.error}"
        ret = false
      end
      return ret
    end

    # Disconnect from the MySQL database
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def disconnect
      @dbh.close if (@dbh != nil)
    end

    # Run a query
    #
    # Arguments
    # * query: string that contains the sql query
    # Output
    # * return a MySQL::result and print an error if the execution failed
    def run_query(query)
      res = nil
      begin
        res = @dbh.query(query)
      rescue Mysql::Error => e
        puts "Error code: #{e.errno}"
        puts "Error message: #{e.error}"
      end
      return res
    end

    # Get the number of affected rows
    #
    # Arguments
    # * nothing
    # Output
    # * return the number of affected rows
    def get_nb_affected_rows
      return @dbh.affected_rows
    end
  end
end
