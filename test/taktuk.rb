$:.unshift File.join(File.dirname(__FILE__), '..', 'src','lib')

require 'taktuk_wrapper'
require 'pp'

res = taktuk('nodefile',:connector=>'ssh -l root',:self_propagate => nil).broadcast_exec['cat -; ls I_DO_NOT_EXIST'].seq!.broadcast_input_file['nodefile'].seq!.broadcast_exec['echo YOUPI'].run!

puts '=== Output ==='
pp res[:output]
puts '=== Aggregated Output ==='
pp res[:output].aggregate(TakTukWrapper::DefaultAggregator.new)
puts '=== Status ==='
pp res[:status]
puts '=== Error ==='
pp res[:error]
