require 'pp'
require 'thread'

# Hacks that allow better dump of internal structures
class Mutex
  def inspect
    "#<#{self.class}:0x#{self.__id__.to_s(16)} locked=#{self.locked?}>"
  end
end

module Kadeploy
  def self.dump(file=nil,width=80)
    if $kadeploy
      file = STDOUT unless file
      PP.pp($kadeploy,file,width)
    end
    objects = Hash.new(0)
    ObjectSpace.each_object{|obj| objects[obj.class] += 1 }
    PP.pp(objects.sort_by{|k,v| -v},file,width)
    objects = nil
    PP.pp(GC.stat,file,width) if GC.respond_to?(:stat)
  end
end
