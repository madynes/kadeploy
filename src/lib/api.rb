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
      when :stat, :stats
        '/stats'
      when :env, :envs
        '/environments'
      when :node, :nodes
        '/nodes'
      when :right, :rights
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
