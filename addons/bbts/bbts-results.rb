#!/usr/bin/ruby

require 'pp'
require 'yaml'

if ARGV.size < 1
	$stderr.puts "usage: #{$0} <file1> <file2> <...> <filen>"
	exit 1
end

def average(values)
  sum = values.inject(0){ |tmpsum,v| tmpsum + v.to_f }
  return sum / values.size
end

def stddev(values,avg = nil)
  avg = average(values) unless avg
  sum = values.inject(0){ |tmpsum,v| tmpsum + ((v.to_f-avg) ** 2) }
  return Math.sqrt(sum / values.size)
end

def confint(values,factor, avg = nil, stddev = nil)
  avg = average(values) unless avg
  stddev = stddev(values) unless stddev
  tmp = ((factor * stddev) / Math.sqrt(values.size))
  return ((avg-tmp)..(avg+tmp)) 
end

$stats = {}

ARGV.each do |file|
	unless File.exists?(file)
		$stderr.puts "file not found '#{file}', ignoring"
		next
  end
  content = YAML.load_file(file)
	unless content.is_a?(Array)
		$stderr.puts "not a valid YAML file '#{file}', ignoring"
		next
  end
  content.each do |res|
=begin
  content = File.read(file).grep(/^ *-/).join
  content.split('---').each do |block|
    res = []
    block = block.strip
    next if block.empty? or !block or block.downcase.include?('summary')
    block.split("\n").each do |str|
      res << str.gsub(/^ *- */,'').strip
    end
    res = YAML.load(res.join("\n"))
=end
    env = res['env']
    automata = res['testname']
    kind = res['kind']
    nodes_tot = res['nodes']['list'].size
    if nodes_tot > 0
      $stats[automata] = {} unless $stats[automata]
      $stats[automata][kind] = {} unless $stats[automata][kind]
      $stats[automata][kind][env] = {} unless $stats[automata][kind][env]
      $stats[automata][kind][env][nodes_tot] = [] unless $stats[automata][kind][env][nodes_tot]
      $stats[automata][kind][env][nodes_tot] <<  {
        :ok => res['nodes']['ok'],
        :time => res['time']
      }
    end
  end
end

$stats.each_pair do |automata,kinds|
  puts "#{automata}:"
  kinds.each_pair do |kind,envs|
    puts "  #{kind}:"
    envs.each_pair do |nodes,tots|
      puts "    #{nodes}:"
      tots.each_pair do |tot,stats|
        nozero = stats.select { |node| node[:ok] > 0 }
        puts "      #{tot} nodes:"
        times = nozero.collect { |node| node[:time] }
        avg = average(times)
        std = stddev(times,avg)
        conf = confint(times,1.96,avg,std)
        puts "        times:"
        puts "          min: #{times.min}"
        puts "          max: #{times.max}"
        puts "          average: #{sprintf('%.2f',avg)}"
        puts "          std dev: #{sprintf('%.2f',std)}"
        puts "          95% conf. int.: [#{sprintf('%.1f',conf.first)};#{sprintf('%.1f',conf.last)}]"
        puts "          nb val: #{times.size}"
        puts "          values: {#{times.join(', ')}}"

        oks = nozero.collect { |node| node[:ok] }
        avg = average(oks)
        std = stddev(oks,avg)
        conf = confint(oks,1.96,avg,std)
        puts "        oks:"
        puts "          min: #{oks.min}"
        puts "          max: #{oks.max}"
        puts "          average: #{sprintf('%.1f',average(oks))}"
        puts "          std dev: #{sprintf('%.2f',std)}"
        puts "          95% conf. int.: [#{sprintf('%.1f',conf.first)};#{sprintf('%.1f',conf.last)}]"
        puts "          nb val: #{oks.size}"
        puts "          values: {#{oks.join(', ')}}"
        puts "        total fails: #{stats.size - nozero.size}"
      end
    end
  end
end
