module Kadeploy

module Kaconsole
  def console_init_exec_context()
    ret = init_exec_context()
    ret.config = nil
    ret
  end

  def console_free_exec_context(context)
    context = free_exec_context(context)
    context.config.free
    context.config = nil
    context
  end

  def console_prepare(params,operation=:get)
    context = console_init_exec_context()
    parse_params_default(params,context)
    context.config = duplicate_config()
    context
  end

  def console_get(cexec,node)
    # TODO: kill the console when the user loose the rights
    if cexec.rights.granted?(cexec.user,[node],'')
      parse_params({'node'=>node}) do |p|
        node = p.parse('node',String,:type=>:node,:mandatory=>true)
      end
      cmd = node.cmd.console || cexec.config.clusters[node.cluster].cmd_console
      cmd = Nodes::NodeCmd.generate(cmd.dup,node)
      { 'command' => cmd }
    else
      kaerror(APIError::INVALID_RIGHTS)
    end
  end
end

end
