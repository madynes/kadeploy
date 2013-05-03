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

$results = {}
$stats.each_pair do |automata,kinds|
  $results[automata] = {}
  kinds.each_pair do |kind,envs|
    $results[automata][kind] = {}
    envs.each_pair do |env,tots|
      $results[automata][kind][env] = {}
      tots.each_pair do |tot,stats|
        nozero = stats.select { |node| node[:ok] > 0 }
        $results[automata][kind][env][tot] = {}

        times = nozero.collect { |node| node[:time] }
        avg = average(times)
        std = stddev(times,avg)
        conf = confint(times,1.96,avg,std)
        $results[automata][kind][env][tot]['timings'] = {
          'min' => times.min,
          'max' => times.max,
          'average' => sprintf('%.2f',avg).to_f,
          'std_dev' => sprintf('%.2f',std).to_f,
          '95_conf_int' => {
            'binf' => sprintf('%.1f',conf.first).to_f,
            'bsup' => sprintf('%.1f',conf.last).to_f,
          },
          'values' => times.clone,
        }

        oks = nozero.collect { |node| node[:ok] }
        avg = average(oks)
        std = stddev(oks,avg)
        conf = confint(oks,1.96,avg,std)
        $results[automata][kind][env][tot]['success'] = {
          'min' => oks.min,
          'max' => oks.max,
          'average' => sprintf('%.1f',average(oks)).to_f,
          'std_dev' => sprintf('%.2f',std).to_f,
          '95_conf_int' => {
            'binf' => sprintf('%.1f',conf.first).to_f,
            'bsup' => sprintf('%.1f',conf.last).to_f,
          },
          'values' => oks.clone,
        }

        $results[automata][kind][env][tot]['complete_failure'] = (stats.size - nozero.size)
      end
    end
  end
end
puts $results.to_yaml
