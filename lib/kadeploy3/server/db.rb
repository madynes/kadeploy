require 'mysql'
require 'timeout'

module Kadeploy

module Database
  def self.where_nodelist(nodes,field='node')
    ["(#{(["(#{field} = ? )"] * nodes.size).join(' OR ')})", nodes] if nodes and !nodes.empty?
  end

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

    # Abstract method to disconnect from the database and free internal data structures
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def free
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

  # Handle database results
  class DbResult
    attr_reader :fields, :affected_rows

    def initialize(fields, content, affected_rows)
      @fields = fields || []
      @content = content || []
      @affected_rows = affected_rows || 0

      @cache_hash = nil
    end

    def free
      @fields = nil
      @content = nil
      @affected_rows = nil
      @cache_hash = nil
    end

    def each_array(&block)
      to_array().each(&block)
    end

    def each_hash(&block)
      to_hash().each(&block)
    end

    def to_array
      return @content
    end
    alias_method :each, :each_array

    def to_hash
      unless @cache_hash
        @cache_hash = []

        @content.each do |row|
          @cache_hash << Hash[*(@fields.zip(row).flatten)]
        end
      end

      return @cache_hash
    end

    def size
      return @content.size
    end
    alias_method :num_rows, :size
  end

  class DbMysql < Db
    def free()
      @dbh.close if (@dbh != nil)
      @dbh = nil
    end

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
        Timeout.timeout(60) do
          @dbh = Mysql.init
          @dbh.options(Mysql::SET_CHARSET_NAME,'utf8')
          @dbh.real_connect(host, user, passwd, base)
          @dbh.reconnect = true
        end
      rescue Timeout::Error
        $stderr.puts "[#{Time.now}] MySQL error: Timeout when connecting to DB (#{user}@#{host}/#{base})"
        $stderr.flush
        ret = false
      rescue Mysql::Error => e
        $stderr.puts "[#{Time.now}] MySQL error (code): #{e.errno}"
        $stderr.puts "[#{Time.now}] MySQL error (message): #{e.error}"
        $stderr.puts "[#{Time.now}] Kadeploy server cannot connect to DB #{user}@#{host}/#{base}"
        $stderr.flush
        ret = false
      end
      return ret
    end

    # Run a query using SQL
    #
    # Arguments
    # * query: string that contains the sql query where each variable should be replaced by '?'
    # * *args: variables that will take the place of the '?'s in the request
    # Output
    # * return a DbResult Object and print an error if the execution failed
    def run_query(query, *args)
      res = nil
      begin
        st = @dbh.prepare(query)
        st.execute(*args)

        content = nil
        fields = nil
        if st.result_metadata
          content = []
          fields = st.result_metadata.fetch_fields.collect{ |f| f.name }
          st.each do |row|
            content << row
          end
        end
        res = DbResult.new(fields,content,st.affected_rows)

        st.close
      rescue Mysql::Error => e
        $stderr.puts "MySQL query: #{query.gsub(/\s+/," ").strip}" if query
        $stderr.puts "MySQL args: #{args.inspect}" if args
        $stderr.puts "MySQL error (code): #{e.errno}"
        $stderr.puts "MySQL error (message): #{e.error}"
        $stderr.puts e.backtrace
        raise KadeployError.new(APIError::DATABASE_ERROR,nil,
          "MySQL error ##{e.errno}: #{e.error.gsub(/\s+/," ").strip}")
      end
      return res
    end
  end
end

end
