#!/usr/bin/ruby -w

# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

require 'optparse'
require 'yaml'

RESULTS=Array.new

def count_lines(filename)
  count = `(wc -l #{filename} 2>/dev/null || echo 0) | cut -f 1 -d" "`
  return count
end

def add_result(kind, env, testname, result, time, ok, ko)
  h = Hash.new
  h["kind"] = kind
  h["env"] = env
  h["testname"] = testname
  h["result"] = result
  h["time"] = time
  h["ok"] = ok.to_i
  h["ko"] = ko.to_i
  RESULTS.push(h)
end

def show_results
  puts "--- Summary ---"
  RESULTS.each { |h|
    puts "---"
    puts " - kind: #{h["kind"]}"
    puts " - name: #{h["testname"]}"
    puts " - environment: #{h["env"]}"
    puts " - time: #{h["time"]}"
    puts " - result: #{h["result"]} - #{h["ok"]}/#{(h["ok"] + h["ko"])}"
  }
end

def load_cmdline_options
  nodes = Array.new
  key = String.new
  automata_file = String.new
  kadeploy = "kadeploy3"
  env_list = "lenny-x64-base"
  max_simult = 4
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
        puts "The file #{f} does not exist"
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
        puts "The file #{f} does not exist"
        return []
      end
      key = File.expand_path(f)
    }
    opts.on("--max-simult NB", "Maximum number of simultaneous deployments") { |n|
      max_simult = n
    }
    opts.on("--env-list LIST", "Environment list (eg. lenny-x64-base,lenny-x64-big,sid-x64-base)") { |l|
      env_list = l
    }
    opts.on("--kadeploy-cmd CMD", "Kadeploy command") { |cmd|
      kadeploy = cmd
    }
  end
  opts.parse!(ARGV)
  return nodes, key, automata_file, kadeploy, env_list, max_simult
end
  

def _test_deploy(nodes, step1, step2, step3, test_name, key, env, kadeploy, max_simult, ok = "nodes_ok", ko = "nodes_ko")
  puts "# Launching test #{test_name} with #{env} env"
  File.delete(ok) if File.exist?(ok)
  File.delete(ko) if File.exist?(ko)
  node_list = String.new
  nodes.each { |node|
    node_list += " -m #{node}"
  }
  cmd = "#{kadeploy} #{node_list} -e \"#{env}\" --verbose-level 0 -k #{key} --force-steps \"SetDeploymentEnv|#{step1}&BroadcastEnv|#{step2}&BootNewEnv|#{step3}\" -o #{ok} -n #{ko}"
  system(cmd)
  if File.exist?(ko) then
    IO.readlines(ko).each { |node|
      puts "The node #{node.chomp} has not been correctly deployed"
    }
  end
  if File.exist?(ok) then
    deployed_nodes = Array.new
    IO.readlines(ok).each { |node|
      deployed_nodes.push(node.chomp)
    }
    results = Hash.new
    deployed_nodes.each { |node|
      cmd = "ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey -o ConnectTimeout=2 root@#{node} \"true\""
      res = system(cmd)
      results[node] = res
    }
    no_errors = true
    results.each_pair { |node,res|
      if not res then
        puts "Connection error on the node #{node}"
        no_errors = false
      end
    }
    return no_errors, count_lines(ok), count_lines(ko)
  else
    return false, count_lines(ok), count_lines(ko)
  end
end

def test_deploy(nodes, step1, step2, step3, test_name, key, kadeploy, env_list, max_simult)
  env_list.split(",").each { |env|
    start = Time.now.to_i
    res, nok, nko = _test_deploy(nodes, step1, step2, step3, test_name, key, env, kadeploy, max_simult)
    time = Time.now.to_i - start
    if res then
      add_result("seq", env, test_name, "ok", time, nok, nko)
      puts "[ PASSED ] (#{time}s)"
    else
      add_result("seq", env, test_name, "ko", time, nok, nko)
      puts "[ ERROR ] (#{time}s)"
    end
  }
end

def test_simultaneous_deployments(nodes, step1, step2, step3, test_name, key, kadeploy, env_list, max_simult)
  simult = 2
  env = env_list.split(",")[0]
  while ((simult <= nodes.length()) && (simult <= max_simult)) do
    start = Time.now.to_i
    puts "*** Performing #{simult} simultaneous deployments"
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
        r, o, k = _test_deploy(nodes_hash[n], step1, step2, step3, test_name, key, env, kadeploy, max_simult, "nodes_ok_#{n}", "nodes_ko_#{n}")
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
      add_result("simult #{simult}", env, test_name, "ok", time, nodes_ok, nodes_ko)
      puts "[ PASSED ] (#{time}s)"
    else
      add_result("simult #{simult}", env, test_name, "ko", time, nodes_ok, nodes_ko)
      puts "[ ERROR ] (#{time}s)"
    end
    simult += 2
  end
end

def test_dummy(nodes, step1, step2, step3, test_name, kadeploy, env_list, max_simult, ok = "nodes_ok", ko = "nodes_ko")
  puts "# Launching test #{test_name}"
  File.delete(ok) if File.exist?(ok)
  File.delete(ko) if File.exist?(ko)
  node_list = String.new
  nodes.each { |node|
    node_list += " -m #{node}"
  }
  cmd = "#{kadeploy} #{node_list} -e \"#{env_list.split(",")[0]}\" --verbose-level 0 --force-steps \"SetDeploymentEnv|#{step1}&BroadcastEnv|#{step2}&BootNewEnv|#{step3}\" -o #{ok} -n #{ko}"
  start = Time.now.to_i
  system(cmd)
  time = Time.now.to_i - start
  if File.exist?(ko) then
    add_result("seq", "dummy", test_name, "ko", time, count_lines(ok), count_lines(ko))
    puts "[ ERROR ] (#{time}s)"
  else
    add_result("seq", "dummy", test_name, "ok", time, count_lines(ok), count_lines(ko))
    puts "[ PASSED ] (#{time}s)"
  end
end

nodes, key, automata_file, kadeploy, env_list, max_simult = load_cmdline_options
if nodes.empty? then
  puts "You must specify at least on node, use --help option for correct use"
  exit(1)
end
if (key == "") || (not File.readable?(key)) then
  puts "You must specify an SSH public key (a readable file), use --help option for correct use"
  exit(1)
end
if (automata_file == "") || (not File.readable?(automata_file)) then
  puts "You must specify an automata file (a readable file), use --help option for correct use"
  exit(1)
end

IO.readlines(automata_file).each { |line|
  if not (/^#/ =~ line) then
    if /\A(dummy|simple|simult)\ ([a-zA-Z0-9\-]+)\ ([a-zA-Z0-9\:]+)\,([a-zA-Z0-9\:]+)\,([a-zA-Z0-9\:]+)\Z/ =~ line then
      content = Regexp.last_match
      kind = content[1]
      test_name = content[2]
      step1 = content[3]
      step2 = content[4]
      step3 = content[5]
      case kind
      when "dummy"
        test_dummy(nodes, step1, step2, step3, test_name, kadeploy, env_list, max_simult)
      when "simple"
        test_deploy(nodes, step1, step2, step3, test_name, key, kadeploy, env_list, max_simult)
      when "simult"
        test_simultaneous_deployments(nodes, step1, step2, step3, test_name, key, kadeploy, env_list, max_simult)
      end
    end
  end
}

show_results()

exit 0
