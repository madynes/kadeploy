#!/usr/bin/ruby -w

# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

Signal.trap("INT") do
  puts "\nSIGINT, killing everything"
  exit!(1)
end

require 'optparse'
require 'yaml'
require 'tempfile'

$results=Array.new

def count_lines(filename)
  count = `(wc -l #{filename} 2>/dev/null || echo 0) | cut -f 1 -d" "`
  return count.to_i
end

def add_result(kind, env, testname, nodes, result, time, ok, ko)
  h = Hash.new
  h["kind"] = kind
  h["env"] = env
  h["testname"] = testname
  h["time"] = time
  h["status"] = result
  h["nodes"] = {}
  h["nodes"]["list"] = nodes.clone
  h["nodes"]["ok"] = ok.to_i
  h["nodes"]["ko"] = ko.to_i
  $results.push(h)
end

def show_results
  puts $results.to_yaml
end

def load_cmdline_options
  nodes = Array.new
  key = String.new
  automata_file = String.new
  kadeploy = "kadeploy3"
  simult_list = "1"
  env_list = "squeeze-x64-base"
  widf = nil
  progname = File::basename($PROGRAM_NAME)
  opts = OptionParser::new do |opts|
    opts.summary_indent = "  "
    opts.summary_width = 28
    opts.program_name = progname
    opts.banner = "Usage: #{progname} [options]"
    opts.separator "Contact: Emmanuel Jeanvoine <emmanuel.jeanvoine@inria.fr>"
    opts.separator ""
    opts.separator "General options:"
    opts.on("-a", "--automata-file FILE", "Automata file") { |f|
      if not File.exist?(f) then
        $stderr.puts "The file #{f} does not exist"
        return []
      end
      automata_file = File.expand_path(f)
    }
    opts.on("-m", "--machine MACHINE", "Node to run on") { |hostname|
      nodes.push(hostname)
    }
    opts.on("-f", "--file MACHINELIST", "Files containing list of nodes")  { |f|
      IO.readlines(f).sort.uniq.each { |hostname|
        nodes.push(hostname.chomp)
      }
    }
    opts.on("-k", "--key FILE", "Public key to copy in the root's authorized_keys") { |f|
      if not File.exist?(f) then
        $stderr.puts "The file #{f} does not exist"
        return []
      end
      key = File.expand_path(f)
    }
    opts.on("--simult LIST", "A list of simult deployment values (eg. 2,4,8)") { |l|
      simult_list = l
    }
    opts.on("--env-list LIST", "Environment list (eg. lenny-x64-base,lenny-x64-big,sid-x64-base)") { |l|
      env_list = l
    }
    opts.on("--kadeploy-cmd CMD", "Kadeploy command") { |cmd|
      kadeploy = cmd
    }
    opts.on("--workflow-id-file FILE", "A file to save workflow IDs") { |f|
      widf = File.expand_path(f)
    }
  end
  opts.parse!(ARGV)
  return nodes, key, automata_file, kadeploy, env_list, simult_list, widf
end
  

def _test_deploy(nodes, step1, step2, step3, test_name, key, env, kadeploy, widf = nil, checks = true, simultid = nil)
  $stderr.puts("\n### Launch[#{test_name}/#{env}#{(simultid ? "(#{simultid})" : '')}]")
  ok_file = Tempfile.new("blackboxtests-ok")
  ok = ok_file.path
  ko_file = Tempfile.new("blackboxtests-ko")
  ko = ko_file.path

  node_list = String.new
  nodes.each { |node|
    node_list += " -m #{node}"
  }
  automata_opt=''
  if step1 and step2 and step3
    automata_opt = "--force-steps \""\
      "SetDeploymentEnv|#{step1}&"\
      "BroadcastEnv|#{step2}&"\
      "BootNewEnv|#{step3}"\
    "\""
  end

  wid_file = nil
  wid_file = Tempfile.new("widfile") if widf

  cmd = "#{kadeploy} #{node_list} -e \"#{env}\" -o #{ok} -n #{ko}"
  cmd += " #{automata_opt}" if automata_opt and !automata_opt.empty?
  cmd += " -k #{key}" if key
  cmd += " --write-workflow-id #{wid_file.path}" if widf

  cmd += " | sed 's/.*/(#{simultid}) &/'" if simultid
  cmd += " 1>&2"

  system(cmd)

  unless $?.success?
    $stderr.puts 'Kadeploy command failed, exiting'
    $stderr.puts cmd
    exit!(1)
  end

  if widf
    system("cat #{wid_file.path} >> #{widf}")
    wid_file.unlink
  end

  return (count_lines(ko) > 0), count_lines(ok), count_lines(ko) unless checks
  if (count_lines(ko) > 0) then
    IO.readlines(ko).each { |node|
      $stderr.puts "### KO[#{node.chomp}]"
    }
  end
  if (count_lines(ok) > 0) then
    deployed_nodes = Array.new
    IO.readlines(ok).each { |node|
      deployed_nodes.push(node.chomp)
    }
    results = Hash.new
    deployed_nodes.each { |node|
      cmd = "ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey -o ConnectTimeout=2 root@#{node} \"true\" 1>&2"
      res = system(cmd)
      results[node] = res
    }
    no_errors = true
    results.each_pair { |node,res|
      if not res then
        $stderr.puts "### CantConnect[#{node}]"
        no_errors = false
      end
    }
    return no_errors, count_lines(ok), count_lines(ko)
  else
    return false, count_lines(ok), count_lines(ko)
  end
end

def test_dummy(nodes, step1, step2, step3, test_name, kadeploy, env_list, widf=nil)
  start = Time.now.to_i
  res, nok, nko = _test_deploy(nodes, step1, step2, step3, test_name, nil, env_list.split(",")[0], kadeploy, widf, false)
  time = Time.now.to_i - start
  if res then
    add_result("seq", "dummy", test_name, nodes, "ok", time, nok, nko)
  else
    add_result("seq", "dummy", test_name, nodes, "ko", time, nok, nko)
  end
end

def test_deploy(nodes, step1, step2, step3, test_name, key, kadeploy, env_list, widf=nil)
  env_list.split(",").each { |env|
    start = Time.now.to_i
    res, nok, nko = _test_deploy(nodes, step1, step2, step3, test_name, key, env, kadeploy, widf)
    time = Time.now.to_i - start
    if res then
      add_result("seq", env, test_name, nodes, "ok", time, nok, nko)
    else
      add_result("seq", env, test_name, nodes, "ko", time, nok, nko)
    end
  }
end

def test_simultaneous_deployments(nodes, step1, step2, step3, test_name, key, kadeploy, env_list, simult_list, widf=nil)
  env = env_list.split(",")[0]
  simult_list.split(',').collect!{|v| v.to_i}.each do |simult|
    start = Time.now.to_i
    nodes_hash = Hash.new
    (0...simult).to_a.each { |n|
      nodes_hash[n] = Array.new
    }
    nodes.each_index { |i|
      nodes_hash[i.modulo(simult)].push(nodes[i])
    }
    tid_array = Array.new
    tid_hash_result = Hash.new
    (0...simult).to_a.each { |n|
      tid = Thread.new {
        r, o, k = _test_deploy(nodes_hash[n], step1, step2, step3, test_name, key, env, kadeploy, widf, true, "#{simult}:#{n}")
        tid_hash_result[tid] = [r, o, k]
      }
      tid_array << tid
    }
    result = true
    nodes_ok = 0
    nodes_ko = 0
    tid_array.each { |tid|
      tid.join
      nodes_ok += tid_hash_result[tid][1].to_i
      nodes_ko += tid_hash_result[tid][2].to_i
      if not tid_hash_result[tid][0] then
        result = false
      end
    }
    time = Time.now.to_i - start
    if result then
      add_result("simult-#{simult}", env, test_name, nodes, "ok", time, nodes_ok, nodes_ko)
    else
      add_result("simult-#{simult}", env, test_name, nodes, "ko", time, nodes_ok, nodes_ko)
    end
  end
end

nodes, key, automata_file, kadeploy, env_list, simult_list, widf = load_cmdline_options
if nodes.empty? then
  $stderr.puts "You must specify at least on node, use --help option for correct use"
  exit(1)
end
if (key == "") || (not File.readable?(key)) then
  $stderr.puts "You must specify an SSH public key (a readable file), use --help option for correct use"
  exit(1)
end
if (automata_file == "") || (not File.readable?(automata_file)) then
  $stderr.puts "You must specify an automata file (a readable file), use --help option for correct use"
  exit(1)
end

IO.readlines(automata_file).each { |line|
  if not (/^#/ =~ line) then
    if /\A(dummy|simple|simult)\s+([a-zA-Z0-9\-]+)\s*(?:\s+([a-zA-Z0-9:,]+)\|([a-zA-Z0-9:,]+)\|([a-zA-Z0-9:,]+))?\Z/ =~ line then
      content = Regexp.last_match
      kind = content[1]
      test_name = content[2]
      step1 = content[3]
      step2 = content[4]
      step3 = content[5]
      case kind
      when "dummy"
        test_dummy(nodes, step1, step2, step3, test_name, kadeploy, env_list)
      when "simple"
        test_deploy(nodes, step1, step2, step3, test_name, key, kadeploy, env_list, widf)
      when "simult"
        test_simultaneous_deployments(nodes, step1, step2, step3, test_name, key, kadeploy, env_list, simult_list, widf)
      end
    end
  end
}

show_results()

exit 0
