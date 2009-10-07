#!/usr/bin/ruby -w

# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'config'
require 'db'

#Ruby libs
require 'drb'

# Generate some filters for the output according the options
#
# Arguments
# * config: instance of Config
# Output
# * return a string that contains the where clause corresponding to the filters required
def append_generic_where_clause(config)
  generic_where_clause = String.new
  node_list = String.new
  hosts = Array.new
  date_min = String.new
  date_max = String.new
  if (not config.exec_specific.node_list.empty?) then
    config.exec_specific.node_list.each { |node|
      if /\A[A-Za-z\.\-]+[0-9]*\[[\d{1,3}\-,\d{1,3}]+\][A-Za-z0-9\.\-]*\Z/ =~ node then
        nodes = Nodes::NodeSet::nodes_list_expand("#{node}")
      else
        nodes = [node]
      end     
      nodes.each{ |n|
        hosts.push("hostname=\"#{n}\"")
      }
    }
    node_list = "(#{hosts.join(" OR ")})"
  end
  if (config.exec_specific.date_min != 0) then
    date_min = "start>=\"#{config.exec_specific.date_min}\""
  end
  if (config.exec_specific.date_max != 0) then
    date_max = "start<=\"#{config.exec_specific.date_max}\""
  end
  if ((node_list != "") || (date_min != "") || (date_max !="")) then
    generic_where_clause = "#{node_list} AND #{date_min} AND #{date_max}"
    #let's clean empty things
    generic_where_clause = generic_where_clause.gsub("AND  AND","")
    generic_where_clause = generic_where_clause.gsub(/^ AND/,"")
    generic_where_clause = generic_where_clause.gsub(/AND $/,"")
  end
  return generic_where_clause
end


# Select the fields to output
#
# Arguments
# * row: hashtable that contains a line of information fetched in the database
# * config: instance of Config
# * default_fields: array of fields used to produce the output if no fields are given in the command line
# Output
# * string that contains the selected fields in a result line
def select_fields(row, config, default_fields)
  fields = Array.new  
  if (not config.exec_specific.fields.empty?) then
    config.exec_specific.fields.each{ |f|
      fields.push(row[f].gsub("\n", "\\n"))
    }
  else
    default_fields.each { |f|
      fields.push(row[f].gsub("\n", "\\n"))
    }
  end
  return fields.join(",")
end

# List the information about the nodes that require a given number of retries to be deployed
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * print the filtred information about the nodes that require a given number of retries to be deployed
def list_retries(config, db)
  step_list = String.new
  steps = Array.new
  if (not config.exec_specific.steps.empty?) then
    config.exec_specific.steps.each { |step|
      case step
      when "1"
        steps.push("retry_step1>=\"#{config.exec_specific.min_retries}\"")
      when "2"
        steps.push("retry_step2>=\"#{config.exec_specific.min_retries}\"")
      when "3"
        steps.push("retry_step3>=\"#{config.exec_specific.min_retries}\"")
      end
    }
    step_list = steps.join(" AND ")
  else
    step_list += "(retry_step1>=\"#{config.exec_specific.min_retries}\""
    step_list += " OR retry_step2>=\"#{config.exec_specific.min_retries}\""
    step_list += " OR retry_step3>=\"#{config.exec_specific.min_retries}\")"
  end

  generic_where_clause = append_generic_where_clause(config)
  if (generic_where_clause == "") then
    query = "SELECT * FROM log WHERE #{step_list}"
  else
    query = "SELECT * FROM log WHERE #{generic_where_clause} AND #{step_list}"
  end
  res = db.run_query(query)
  if (res.num_rows > 0) then
    res.each_hash { |row|
      puts select_fields(row, config, ["start","hostname","retry_step1","retry_step2","retry_step3"])
    }
  else
    puts "No information is available"
  end
end


# List the information about the nodes that have at least a given failure rate
#
# Arguments
# * config: instance of Config
# * db: database handler
# * min(opt): minimum failure rate
# Output
# * print the filtred information about the nodes that have at least a given failure rate
def list_failure_rate(config, db, min = nil)
  generic_where_clause = append_generic_where_clause(config)
  if (generic_where_clause != "") then
    query = "SELECT * FROM log WHERE #{generic_where_clause}"
  else
    query = "SELECT * FROM log"
  end
  res = db.run_query(query)
  if (res.num_rows > 0) then
    hash = Hash.new
    res.each_hash { |row|
      if (not hash.has_key?(row["hostname"])) then
        hash[row["hostname"]] = Array.new
      end
      hash[row["hostname"]].push(row["success"])
    }
    hash.each_pair { |hostname, array|
      success = 0
      array.each { |val|
        if (val == "true") then
          success += 1
        end
      }
      rate = 100 - (100 * success / array.length)
      if ((min == nil) || (rate >= min)) then
        puts "#{hostname}: #{rate}%"
      end
    }
  else
    puts "No information is available"
  end
end

# List the information about all the nodes
#
# Arguments
# * config: instance of Config
# * db: database handler
# Output
# * print the information about all the nodes
def list_all(config, db)
  generic_where_clause = append_generic_where_clause(config)
  if (generic_where_clause != "") then
    query = "SELECT * FROM log WHERE #{generic_where_clause}"
  else
    query = "SELECT * FROM log"
  end
  res = db.run_query(query)
  if (res.num_rows > 0) then
    res.each_hash { |row|
      puts select_fields(row, config, ["user","hostname","step1","step2","step3", \
                                       "timeout_step1","timeout_step2","timeout_step3", \
                                       "retry_step1","retry_step2","retry_step3", \
                                       "start", \
                                       "step1_duration","step2_duration","step3_duration", \
                                       "env","anonymous_env","md5", \
                                       "success","error"])
    }
  else
    puts "No information is available"
  end
end

def _exit(exit_code, dbh)
  dbh.disconnect if (dbh != nil)
  exit(exit_code)
end

begin
  config = ConfigInformation::Config.new("kastat")
rescue
  _exit(1, nil)
end
#Connect to the Kadeploy server to get the common configuration
client_config = ConfigInformation::Config.load_client_config_file
DRb.start_service()
uri = "druby://#{client_config.kadeploy_server}:#{client_config.kadeploy_server_port}"
kadeploy_server = DRbObject.new(nil, uri)
config.common = kadeploy_server.get_common_config

if (config.check_config("kastat") == true) then
  if config.exec_specific.get_version then
    puts "Kastat version: #{kadeploy_server.get_version()}"
    _exit(0, nil)
  end
  db = Database::DbFactory.create(config.common.db_kind)
  db.connect(config.common.deploy_db_host,
             config.common.deploy_db_login,
             config.common.deploy_db_passwd,
             config.common.deploy_db_name)

  case config.exec_specific.operation
  when "list_all"
    list_all(config, db)
  when "list_retries"
    list_retries(config, db)
  when "list_failure_rate"
    list_failure_rate(config, db)
  when "list_min_failure_rate"
    list_failure_rate(config, db, config.exec_specific.min_rate)
  end
  _exit(0, db)
else
  _exit(1, db)
end
