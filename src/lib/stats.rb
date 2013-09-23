require 'db'

module Kadeploy

module Stats
  def list_retries(exec_specific, client, db)
    tmpargs, generic_where_clause = kastat_generic_where_clause(exec_specific)
    step_list = String.new

    args = []
    if (not exec_specific.steps.empty?) then
      steps = []
      exec_specific.steps.each { |step|
        case step
        when "1"
          steps.push("retry_step1 >= ?")
          args << exec_specific.min_retries
        when "2"
          steps.push("retry_step2 >= ?")
          args << exec_specific.min_retries
        when "3"
          steps.push("retry_step3 >= ?")
          args << exec_specific.min_retries
        end
      }
      step_list = "(#{steps.join(" AND ")})"
    else
      step_list = "(retry_step1 >= ? OR retry_step2 >= ? OR retry_step3 >= ?)"
      3.times{ args << exec_specific.min_retries }
    end
    args += tmpargs

    query = "SELECT COUNT(*) FROM log WHERE #{step_list}"
    query += " AND #{generic_where_clause}" unless generic_where_clause.empty?
    res = db.run_query(query,*args)

    if res.to_array[0][0] == 0
      Debug::distant_client_print("No information is available", client)
      return false
    end

    (res.to_array[0][0]*1.0/RESULTS_MAX_PER_REQUEST).ceil.times do |i|
      query = "SELECT * FROM log WHERE #{step_list}"
      query += " AND #{generic_where_clause}" unless generic_where_clause.empty?
      query += " LIMIT #{i*RESULTS_MAX_PER_REQUEST},#{RESULTS_MAX_PER_REQUEST}"

      res = db.run_query(query,*args)

      fields = db_generate_fields(res.fields,exec_specific.fields,
        ["start","hostname","retry_step1","retry_step2","retry_step3"]
      )
      db_print_results(res,fields) do |str|
        Debug::distant_client_print(str,client)
      end

      res = nil
      GC.start
    end
    true
  end

  def list_failure_rate(exec_specific, client, db)
    args, generic_where_clause = kastat_generic_where_clause(exec_specific)

    query = "SELECT hostname,COUNT(*) FROM log"
    query += " WHERE #{generic_where_clause}" unless generic_where_clause.empty?
    query += " GROUP BY hostname"

    res = db.run_query(query,*args)
    unless res.num_rows > 0
      Debug::distant_client_print("No information is available", client)
      return
    end

    total = {}
    res.to_array.each do |row|
      total[row[0]] = row[1]
    end

    query = "SELECT hostname,COUNT(*) FROM log"
    query += " WHERE success = ?"
    query += " AND #{generic_where_clause}" unless generic_where_clause.empty?
    query += " GROUP BY hostname"
    args = ['true'] + args
    res = db.run_query(query,*args)

    success = {}
    total.keys.each do |node|
      success[node] = 0
    end
    res.to_array.each do |row|
      success[row[0]] = row[1]
    end

    total.each_pair do |node,tot|
      rate = 100 - (100 * success[node].to_f / tot)
      if (exec_specific.min_rate == nil) or (rate >= exec_specific.min_rate)
        Debug::distant_client_print("#{node}: #{'%.2f'%rate}%", client)
      end
    end
    res = nil
    GC.start
    true
  end

  def self.list_all(db,filters={},fields=nil)
    ret = []
    #query = "SELECT COUNT(*) FROM log"
    where,args = db_filters(filters)
    #query << " WHERE #{where}" unless where.empty?
    #res = db.run_query(query,*args)

    #if res.to_array[0][0] == 0
    #  return []
    #end

    #(res.to_array[0][0]*1.0/RESULTS_MAX_PER_REQUEST).ceil.times do |i|
      query = "SELECT * FROM log"
      query += " WHERE #{where}" unless where.empty?
    #  query += " LIMIT #{i*RESULTS_MAX_PER_REQUEST},#{RESULTS_MAX_PER_REQUEST}"
      res = db.run_query(query,*args)
      ret += db_results(res,fields).to_array
    #end

    ret
  end

  private

  def self.db_filters(filters)
    ret = ''
    args = []

    return ret,args unless filters

    if filters[:date_min]
      ret << ' AND ' unless ret.empty?
      args << filter[:date_min]
      ret << "start >= ?"
    end

    if filters[:date_max]
      ret << ' AND ' unless ret.empty?
      args << filters[:date_max]
      ret << "start <= ?"
    end

    if filters[:wid]
      ret << ' AND ' unless ret.empty?
      args << filters[:wid]
      ret << "deploy_id = ?"
    end

    if filters[:limit] # Has to be the last one
      ret << 'LIMIT ?'
      args << filters[:limit]
    end

    return [args, ret]
  end

  def self.db_results(results,fields=nil)
    if fields
      fields_idx = fields.collect{|f| res.fields.index(f) }
      # TODO: check memory consumption and test with select! or delete_at ...
      results.collect!{|res| res.values_at(*fields_idx) }
      results
    else
      results
    end
  end
end

end
