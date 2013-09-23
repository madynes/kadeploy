require 'stats'

module Kadeploy

module Kastats
  def stats_init_exec_context()
    ret = init_exec_context()
    ret.database = nil
    ret.nodes = nil
    ret.kind = nil
    ret.filters = {}
    ret.fields = nil
    ret
  end

  def stats_prepare(params,operation=:get)
    context = nodes_init_exec_context()
    parse_params_default(params,context)

    context.database = database_handler()

    # Check user/key
    parse_params_default(params,context)

    parse_params(params) do |p|
      # Check nodelist
      context.nodes = p.parse('nodes',Array,:type=>:nodeset,
        :errno=>APIError::INVALID_NODELIST)
      context.nodes = context.nodes.make_array_of_hostname if context.nodes

      context.kind = p.parse('kind',String,:values=>['all','retries','failure_rate'],:default=>'all')
      context.fields = p.parse('fields',Array,:values=>['wid','user','hostname','step1','step2','step3','timeout_step1','timeout_step2','timeout_step3','retry_step1','retry_step2','retry_step3','start','step1_duration','step2_duration','step3_duration','env','md5','success','error'])
      # when by == nil -> all
      # wid = ...
      # min_failure_rate, min_retries
      # limit -> limit number, last -> sort_by_date+limit=1
    end

    context
  end

  def stats_rights?(cexec,operation,names,*args)
    true
  end

  def stats_get(cexec)
    Stats.list_all(cexec.database,cexec.filters,cexec.fields)
  end
end

end
