module Kadeploy

module Kastats
  def stats_init_exec_context(ret)
    ret.nodes = nil
    ret.kind = nil
    ret.filters = {}
    ret.options = {}
    ret.fields = nil
    ret
  end

  def stats_prepare(params,operation,context)
    context = stats_init_exec_context(context)
    operation ||= :get

    parse_params(params) do |p|
      # Check nodelist
      nodes = p.parse('nodes',Array,:type=>:nodeset,
        :errno=>APIError::INVALID_NODELIST)
      if nodes
        tmp = nodes.make_array_of_hostname
        nodes.free
        nodes = nil
        context.filters[:nodes] = tmp
      end

      context.kind = p.parse('kind',String,:values=>['all','failure_rates'],:default=>'all')
      context.fields = p.parse('fields',Array,:values=>['wid','user','hostname','step1','step2','step3','timeout_step1','timeout_step2','timeout_step3','retry_step1','retry_step2','retry_step3','start','step1_duration','step2_duration','step3_duration','env','md5','success','error'], :default=>['wid','user','hostname','step1','step2','step3','timeout_step1','timeout_step2','timeout_step3','retry_step1','retry_step2','retry_step3','start','step1_duration','step2_duration','step3_duration','env','md5','success','error'])

      context.options[:sort] = p.parse('sort',Array,:values=>['wid','user','hostname','step1','step2','step3','timeout_step1','timeout_step2','timeout_step3','retry_step1','retry_step2','retry_step3','start','step1_duration','step2_duration','step3_duration','env','md5','success','error'],:default=>['start'])
      context.options[:limit] = p.parse('limit',String,:regexp=>/^\d+|\d+,\d+$/)
      context.options[:failure_rate] = p.parse('min_failure_rate',String,:regexp=>/^0?\.\d+|1(?:\.0)?$/) # float between 0 and 1

      context.filters[:date_min] = p.parse('date_min',String,:type=>:date)
      context.filters[:date_max] = p.parse('date_max',String,:type=>:date)
      context.filters[:wid] = p.parse('wid',String)
      context.filters[:min_retries] = p.parse('min_retries',String,:regexp=>/^\d+$/)
      context.filters[:step_retries] = p.parse('step_retries',Array,:values=>['1','2','3'])
    end

    context
  end

  def stats_get(cexec,operation=nil)
    if operation
      if ['deploy','reboot','power'].include?(operation.strip)
        operation = operation.to_sym
      else
        error_not_found!
      end
    end

    Stats.send(:"list_#{cexec.kind}",cexec.database,operation,cexec.filters,cexec.options,cexec.fields)
  end
end

end
