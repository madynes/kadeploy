module Kadeploy

module API
  def self.base(kind)
    case kind
      when :deploy
        '/deployment'
      when :reboot
        '/reboot'
      when :power
        '/power'
      when :stats
        '/stats'
      when :envs
        '/environments'
      when :nodes
        '/nodes'
      when :rights
        '/rights'
      else
        raise
    end
  end

  def self.path(kind,*args)
    File.join(base(kind),*args)
  end

  def self.ppath(kind,prefix,*args)
    File.join(prefix,base(kind),*args)
  end
end

end
