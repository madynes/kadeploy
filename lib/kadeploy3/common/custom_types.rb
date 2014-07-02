module Kadeploy

module CustomTypes

class MutableInteger
  def initialize(i=0)
    @mutex=Mutex.new()
    @i = i
  end
  def to_i
    @i
  end
  def inspect
    @i
  end
  def to_s
    @i.to_s
  end
  def inc(i=1)
    @mutex.synchronize do
      @i+=1
    end
  end
  def dec(i=1)
    @mutex.synchronize do
      @i-=1
    end
  end
  def set(i)
    @i=i
  end
end
end
end
