module Kadeploy

module Stats
  MAX_RESULTS_PER_REQUEST=50000

  def self.list_failure_rates(db,operation,filters={},options={},fields=nil)
    where,args = db_filters(operation,filters)
    op,args = db_options(options,args)
    query = "SELECT hostname,COUNT(*) FROM log"
    query << " WHERE #{where}" unless where.empty?
    query << " GROUP BY hostname"
    query << op unless op.empty?
    total = db.run_query(query,*args).to_array

    query = "SELECT hostname,COUNT(*) FROM log"
    query << " WHERE success = 'true'"
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
    total = nil
    if options[:limit]
      total = options[:limit].to_i
      options.delete(:limit)
    else
      where,args = db_filters(operation,filters)
      opt,args = db_options(options,args)
      query = "SELECT COUNT(*) FROM log"
      query << " WHERE #{where}" unless where.empty?
      query << opt unless opt.empty?
      res = db.run_query(query,*args)
      total = res.to_array[0][0]
    end

    ret = nil
    treated = 0
    begin
      ret = CompressedCSV.new()
      if total > 0
        where,args = db_filters(operation,filters)
        opt,args = db_options(options,args)
        tot = total
        (total.to_f/MAX_RESULTS_PER_REQUEST).ceil.times do |i|
          to_treat = (tot>=MAX_RESULTS_PER_REQUEST ? MAX_RESULTS_PER_REQUEST : tot)
          query = "SELECT CONCAT_WS(',',#{fields.join(',')}) FROM log"
          query << " WHERE #{where}" unless where.empty?
          query << opt unless opt.empty?
          query << " LIMIT #{i*MAX_RESULTS_PER_REQUEST},#{to_treat}"

          res = db.run_query(query,*args)
          res.to_array.flatten!.each{|r| ret << r; ret << "\n"}
          res.free

          tot -= MAX_RESULTS_PER_REQUEST
          treated += to_treat
        end
      end
      ret.close
    ensure
      ret.free if ret and !ret.file
    end

    GC.start if treated > 200000

    ret
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
      ret << db_field(table,'wid',"like '#{API.wid_prefix(operation)}%'")
    end

    if filters[:nodes]
      ret << ' AND ' unless ret.empty?
      args += filters[:nodes]
      ret << db_field(table,'hostname',"IN (#{(['?']*filters[:nodes].size).join(',')})")
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
      ret << db_field(table,'wid','= ?')
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
