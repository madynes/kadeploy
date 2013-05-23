module Kastat
  API_DEPLOY_PATH = '/stats'

  def stats_path(path='',prefix='')
    File.join(prefix,API_DEPLOY_PATH,path)
  end

  def stats_prepare(params,operation=:get)
  end

  def stats_rights?(cexec,operation,*args)
  end

  def stats_get(cexec,nodes=nil)
  end
end

