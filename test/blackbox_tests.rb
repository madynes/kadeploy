#!/usr/bin/ruby -w

# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

require 'optparse'
require 'yaml'

KADEPLOY="kadeploy3"
ENV_LIST="lenny-x64-base,lenny-x64-big,sid-x64-base,sid-x64-big"
MAX_SIMULTANEOUS_DEPLOY=4
RESULTS=Array.new

def add_result(kind, testname, result, time)
  h = Hash.new
  h["kind"] = kind
  h["testname"] = testname
  h["result"] = result
  h["time"] = time
  RESULTS.push(h)
end

def show_results
  puts "--- Summary ---"
  RESULTS.each { |h|
    puts "---"
    puts " - kind: #{h["kind"]}"
    puts " - name: #{h["testname"]}"
    puts " - time: #{h["time"]}"
    puts " - result: #{h["result"]}"
  }
end

def load_cmdline_options
  nodes = Array.new
  key = String.new
  progname = File::basename($PROGRAM_NAME)
  opts = OptionParser::new do |opts|
    opts.summary_indent = "  "
    opts.summary_width = 28
    opts.program_name = progname
    opts.banner = "Usage: #{progname} [options]"
    opts.separator "Contact: Emmanuel Jeanvoine <emmanuel.jeanvoine@inria.fr>"
    opts.separator ""
    opts.separator "General options:"
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
  end
  opts.parse!(ARGV)
  return nodes, key
end
  

def _test_deploy(nodes, step1, step2, step3, test_name, key, env, ok = "nodes_ok", ko = "nodes_ko")
  puts "# Launching test #{test_name} with #{env} env"
  File.delete(ok) if File.exist?(ok)
  File.delete(ko) if File.exist?(ko)
  node_list = String.new
  nodes.each { |node|
    node_list += " -m #{node}"
  }
  cmd = "#{KADEPLOY} #{node_list} -e \"#{env}\" --verbose-level 0 -k #{key} --force-steps \"SetDeploymentEnv|#{step1}&BroadcastEnv|#{step2}&BootNewEnv|#{step3}\" -o #{ok} -n #{ko}"
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
    return no_errors
  end
end

def test_deploy(nodes, step1, step2, step3, test_name, key)
  ENV_LIST.split(",").each { |env|
    start = Time.now.to_i
    res = _test_deploy(nodes, step1, step2, step3, test_name, key, env)
    time = Time.now.to_i - start
    if res then
      add_result("seq", test_name, "ok", time)
      puts "[ PASSED ] (#{time}s)"
    else
      add_result("seq", test_name, "ko", time)
      puts "[ ERROR ] (#{time}s)"
    end
  }
end

def test_simultaneous_deployments(nodes, step1, step2, step3, test_name, key)
  simult = 2
  while ((simult <= nodes.length()) && (simult <= MAX_SIMULTANEOUS_DEPLOY)) do
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
    (0...simult).to_a.each { |n|
      tid_array << Thread.new {
        _test_deploy(nodes_hash[n], step1, step2, step3, test_name, key, ENV_LIST.split(",")[0], "nodes_ok_#{n}", "nodes_ko_#{n}")
      }
    }
    result = true
    tid_array.each { |tid|
      if not tid.value then
        result = false
      end
    }
    time = Time.now.to_i - start
    if result then
      add_result("simult", test_name, "ok", time)
      puts "[ PASSED ] (#{time}s)"
    else
      add_result("simult", test_name, "ko", time)
      puts "[ ERROR ] (#{time}s)"
    end
    simult += 2
  end
end

def test_dummy(nodes, step1, step2, step3, test_name, ok = "nodes_ok", ko = "nodes_ko")
  puts "# Launching test #{test_name}"
  File.delete(ok) if File.exist?(ok)
  File.delete(ko) if File.exist?(ko)
  node_list = String.new
  nodes.each { |node|
    node_list += " -m #{node}"
  }
  cmd = "#{KADEPLOY} #{node_list} -e \"#{ENV_LIST.split(",")[0]}\" --verbose-level 0 --force-steps \"SetDeploymentEnv|#{step1}&BroadcastEnv|#{step2}&BootNewEnv|#{step3}\" -o #{ok} -n #{ko}"
  start = Time.now.to_i
  system(cmd)
  time = Time.now.to_i - start
  if File.exist?(ko) then
    add_result("seq", test_name, "ko", time)
    puts "[ ERROR ] (#{time}s)"
  else
    add_result("seq", test_name, "ok", time)
    puts "[ PASSED ] (#{time}s)"
  end
end

nodes, key = load_cmdline_options
if nodes.empty? then
  puts "You must specify at least on node, use --help option for correct use"
  exit(1)
end
if (key == "") || (not File.readable?(key)) then
  puts "You must specify an SSH public key (a readable file), use --help option for correct use"
  exit(1)
end

puts "--------------- Dummy test ------------------"
test_dummy(nodes, "SetDeploymentEnvDummy:1:10", "BroadcastEnvDummy:1:10", "BootNewEnvDummy:1:10", "Dummy")

puts "----------- Simple deploy tests -------------"
#test_deploy(nodes, "SetDeploymentEnvProd:2:100", "BroadcastEnvChainWithFS:2:300", "BootNewEnvKexec:1:150", "ProdEnv - Kexec reboot")
#test_deploy(nodes, "SetDeploymentEnvUntrusted:1:500", "BroadcastEnvChain:1:400", "BootNewEnvKexec:1:400", "UntrustedEnv - Taktuk broadcast - Kexec reboot", key)
#test_deploy(nodes, "SetDeploymentEnvUntrusted:1:500", "BroadcastEnvChain:1:400", "BootNewEnvClassical:1:500", "UntrustedEnv - Taktuk broadcast - Classical reboot", key)
test_deploy(nodes, "SetDeploymentEnvUntrusted:1:500", "BroadcastEnvKastafior:1:400", "BootNewEnvKexec:1:400", "UntrustedEnv - Kastafior broadcast - Kexec reboot", key)
test_deploy(nodes, "SetDeploymentEnvUntrusted:1:500", "BroadcastEnvKastafior:1:400", "BootNewEnvClassical:1:500", "UntrustedEnv - Kastafior broadcast - Classical reboot", key)

puts "-------- Simultaneous deploy tests ----------"
test_simultaneous_deployments(nodes, "SetDeploymentEnvUntrusted:1:500", "BroadcastEnvKastafior:1:400", "BootNewEnvClassical:1:500", "UntrustedEnv - Kastafior broadcast - Classical reboot", key)

show_results()

exit 0
