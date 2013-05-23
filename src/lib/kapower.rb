module Kapower
  API_POWER_PATH = '/power'

  def power_path(path='',prefix='')
    File.join(prefix,API_POWER_PATH,path)
  end

  def power_check_params(params)
    raise
  end

  def power_run(options)
    raise
  end

  def power_get(wid)
    raise
  end

  def power_delete(wid)
    raise
  end
end
