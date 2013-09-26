module Kadeploy

module Kaconsole
  def console_prepare(params,operation=:get)
    context = init_exec_context()
    parse_params_default(params,context)
    context
  end

  def console_get(cexec,node)
    # TODO: kill the console when the user loose the rights
    if cexec.rights.granted?(cexec.user,[node],'')
      parse_params({'node'=>node}) do |p|
        node = p.parse('node',String,:type=>:node,:mandatory=>true)
      end
      { 'command' => node.cmd.console }
    else
      kaerror(APIError::INVALID_RIGHTS)
    end
  end
end

end
