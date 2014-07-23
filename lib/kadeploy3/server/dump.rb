require 'pp'
require 'thread'

# Hacks that allow better dump of internal structures
class Mutex
  def inspect
    "#<#{self.class}:0x#{self.__id__.to_s(16)} locked=#{self.locked?}>"
  end
end

module Kadeploy
  def self.dump(width=80)
    file = STDERR
    GC.start

    objects = Hash.new(0)
    total = ObjectSpace.each_object{|obj| objects[obj.class] += 1 }
    objects[Object] = total

    file.puts("--- Objects by number ---")
    PP.pp(Hash[objects.select{|k,v| v > 4}.sort_by{|k,v| -v}],file,width)

    file.puts("\n--- Objects by name ---")
    PP.pp(Hash[objects.sort_by{|k,v| k.name || ''}],file,width)
    objects = nil

    if ObjectSpace.respond_to?(:count_objects)
      file.puts("\n--- Raw objects ---")
      PP.pp(ObjectSpace.count_objects,file,width)
    end

    if GC.respond_to?(:stat)
      file.puts("\n--- GC stats ---")
      PP.pp(GC.stat,file,width)
    end

    if $kadeploy
      file.puts("\n--- Kadeploy structures ---")
      PP.pp($kadeploy,file,width)
    end

    file.flush
  end
end
