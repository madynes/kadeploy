require 'db'
require 'api'

module Kadeploy

module Stats
  def self.list_failure_rates(db,operation,filters={},options={},fields=nil)
    where,args = db_filters(operation,filters)
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
    total = db.run_query(query,*args).to_array

    query = "SELECT hostname,COUNT(*) FROM log"
    query << " WHERE success = true"
    query << " AND #{where}" unless where.empty?
    query << " GROUP BY hostname"
    query << op unless op.empty?
    success = db.run_query(query,*args).to_array

    ret = {}
    total.each do |tot|
      suc = success.select{|s| s[0] == tot[0]}
      if suc.empty?
        suc = [tot[0],0]
      else
        suc = suc[0]
      end
      rate = 1 - (suc[1].to_f / tot[1])
      if !options[:failure_rate] or rate >= options[:failure_rate].to_f
        ret[tot[0]] = rate.round(3)
      end
    end

    ret
  end

  def self.list_all(db,operation,filters={},options={},fields=nil)
    ret = []
    #query = "SELECT COUNT(*) FROM log"
    where,args = db_filters(operation,filters)
    opt,args = db_options(options,args)
    #query << " WHERE #{where}" unless where.empty?
    #res = db.run_query(query,*args)

    #if res.to_array[0][0] == 0
    #  return []
    #end

    #(res.to_array[0][0]*1.0/RESULTS_MAX_PER_REQUEST).ceil.times do |i|

    # Format output result as CSV String
      query = "SELECT CONCAT_WS(',',#{fields.join(',')}) FROM log"
      query << " WHERE #{where}" unless where.empty?
      query << opt unless opt.empty?
    #  query += " LIMIT #{i*RESULTS_MAX_PER_REQUEST},#{RESULTS_MAX_PER_REQUEST}"
      res = db.run_query(query,*args)
    #end

    if res.affected_rows > 0
      ret = CSV.new(res.to_array.flatten!.join("\n"))
      res.free
      GC.start
      ret
    else
      ''
    end
  end

  private

  def self.db_field(table,name,expr)
    "#{table && (table+'.'+name) || name} #{expr}"
  end

  def self.db_filters(operation,filters,table=nil)
    ret = ''
    args = []

    return ret,args unless filters

    if operation
      ret << ' AND ' unless ret.empty?
      ret << db_field(table,'deploy_id',"like '#{API.wid_prefix(operation)}%'")
    end

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

    if filters[:min_retries]
      ret << ' AND ' unless ret.empty?
      if filters[:step_retries]
        ret << filters[:step_retries].collect{|s| "(retry_step#{s} >= ?)"}.join(' AND ')
        filters[:step_retries].size.times{ args << filters[:min_retries] }
      else
        ret << '(retry_step1 >= ? OR retry_step2 >= ? OR retry_step3 >= ?)'
        3.times{ args << filters[:min_retries] }
      end
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
end

end
