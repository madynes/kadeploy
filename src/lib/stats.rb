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

  def self.list_failure_rates(db,filters={},options={},fields=nil)
    where,args = db_filters(filters)
    op,args = db_options(options,args)
    #query = "SELECT l1.hostname,goods/count(*) AS success
    #  FROM log l1, (
    #      SELECT hostname,IFNULL(rate,0) AS goods
    #      FROM log LEFT JOIN (
    #        SELECT hostname,count(*) AS rate
    #        FROM log
    #        WHERE success = true
    #        GROUP BY hostname
    #      ) l3 USING (hostname) GROUP BY hostname
    #    ) l2
    #  WHERE l1.hostname = l2.hostname"
    #query << " AND #{where} " unless where.empty?
    #query << " GROUP BY l1.hostname"
    #query << op unless op.empty?
    query = "SELECT hostname,COUNT(*) FROM log"
    query << " WHERE #{where}" unless where.empty?
    query << " GROUP BY hostname"
    query << op unless op.empty?
    res = db.run_query(query,*args)
    total = db_results(res)

    query = "SELECT hostname,COUNT(*) FROM log"
    query << " WHERE success = true"
    query << " AND #{where}" unless where.empty?
    query << " GROUP BY hostname"
    query << op unless op.empty?
    res = db.run_query(query,*args)
    success = db_results(res)

    ret = {}
    total.each do |tot|
      suc = success.select{|s| s[0] == tot[0]}
      if suc.empty?
        suc = [tot[0],0]
      else
        suc = success[0]
      end
      rate = suc[1].to_f / tot[1]
      if !options[:failure_rate] or rate >= options[:failure_rate]
        ret[tot[0]] = rate
      end
    end

    ret
  end

  def self.list_all(db,filters={},options={},fields=nil)
    ret = []
    #query = "SELECT COUNT(*) FROM log"
    where,args = db_filters(filters)
    op,args = db_options(options,args)
    #query << " WHERE #{where}" unless where.empty?
    #res = db.run_query(query,*args)

    #if res.to_array[0][0] == 0
    #  return []
    #end

    #(res.to_array[0][0]*1.0/RESULTS_MAX_PER_REQUEST).ceil.times do |i|
      query = "SELECT * FROM log"
      query << " WHERE #{where}" unless where.empty?
      query << op unless op.empty?
    #  query += " LIMIT #{i*RESULTS_MAX_PER_REQUEST},#{RESULTS_MAX_PER_REQUEST}"
p query
p args
      res = db.run_query(query,*args)
      ret += db_results(res,fields)
    #end

    ret
  end

  private

  def self.db_field(table,name,expr)
    "#{table && (table+'.'+name) || name} #{expr}"
  end

  def self.db_filters(filters,table=nil)
    ret = ''
    args = []

    return ret,args unless filters

    if filters[:date_min]
      ret << ' AND ' unless ret.empty?
      args << filters[:date_min].to_i
      ret << db_field(table,'start','>= ?')
    end

    if filters[:date_max]
      ret << ' AND ' unless ret.empty?
      args << filters[:date_max].to_i
      ret << db_field(table,'start','<= ?')
    end

    if filters[:wid]
      ret << ' AND ' unless ret.empty?
      args << filters[:wid]
      ret << db_field(table,'deploy_id','= ?')
    end

    return [ret,args]
  end

  def self.db_options(options,args=[])
    ret = ''

    #if options[:failure_rate]
    #  ret << ' HAVING success >= ?'
    #  args << options[:failure_rate].to_f
    #end

    if options[:sort] # Has to be the last one
      ret << " ORDER BY #{options[:sort].join(',')}"
    end

    if options[:limit]
      ret << ' LIMIT ?'
      args << options[:limit]
    end

    return [ret,args]
  end

  def self.db_results(results,fields=nil)
    if fields
      fields_idx = fields.collect{|f| results.fields.index(f) }
      # TODO: check memory consumption and test with select! or delete_at ...
      results = results.to_array
      results.collect!{|res| res.values_at(*fields_idx) }
      results
    else
      results.to_array
    end
  end
end

end
