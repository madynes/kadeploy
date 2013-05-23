module Kareboot
  API_REBOOT_PATH = '/reboot'

  def reboot_path(path='',prefix='')
    File.join(prefix,API_REBOOT_PATH,path)
  end

  def reboot_check_params(params)
    raise
  end

  def reboot_run(options)
    raise
  end

  def reboot_get(wid)
    raise
  end

  def reboot_delete(wid)
    raise
  end
end
