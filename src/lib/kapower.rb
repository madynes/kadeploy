module Kadeploy

module Kapower
  def power_init_exec_context()
  end

  def power_init_info(cexec)
    # common
  end

  def power_init_resources(cexec)
  end

  def power_prepare(params,operation=:create)
    # common
  end

  def power_rights?(cexec,operation,names,wid=nil,*args)
  end

  def power_create(cexec)
  end

  def power_get(cexec,wid=nil)
  end

  def power_delete(cexec,wid)
  end

  def power_kill(info)
  end

  def power_free(info)
  end

  #def deploy_get_logs(cexec,wid,cluster=nil)
  #def deploy_get_debugs(cexec,wid,node=nil)
  #def deploy_get_state(cexec,wid)
  #def deploy_get_status(cexec,wid)
  #def deploy_get_error(cexec,wid)
end

end
