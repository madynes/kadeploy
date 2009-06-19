require 'thread'

class TaktukWrapper
  attr_reader :argv, :command_line, :hosts, :errors, :connectors, :infos
  attr_accessor :at_output_blocks, :at_status_blocks, :at_taktuk_blocks, :at_connector_blocks, :at_error_blocks, :at_info_blocks


  def initialize(argv)
    @argv = argv
    @mystdin, @stdin = IO::pipe
    @stdout, @mystdout = IO::pipe
    @stderr, @mystderr = IO::pipe
    @at_connector_blocks = Array::new
    @at_error_blocks = Array::new
    @at_output_blocks = Array::new
    @at_status_blocks = Array::new
    @at_taktuk_blocks = Array::new
    @at_info_blocks = Array::new
    @at_exit_blocks = Array::new
    @channels = Hash::new
    @channels = { "1" => [ 7 , @at_output_blocks ] , "2" => [ 7 , @at_error_blocks ] , "3" => [ 8 , @at_status_blocks ] , "4" => [ 4 , @at_info_blocks ]  , "5" => [ 5 , @at_connector_blocks ] , "6" => [ 7 , @at_taktuk_blocks ] }
    host = nil
    eol = nil
    rank = nil
    peer = nil
    pid = nil
    command = nil
    level_name = nil
    package = nil
    line_number = nil
    error = nil
    key = nil
    type = nil
    @hosts = Hash::new { |hash,k| hash[k] = { "host_name" => host, "rank" => rank, "commands" => Hash::new { |hash,k| hash[k] = { "command_line" => command, "pid" => pid, "output" => "", "error" => "", "status" => nil, "start_date" => nil, "stop_date" => nil } } } }
    @errors = Array::new
    @connectors = Hash::new { |hash,k| hash[k] = { "host_name" => host, "peer" => peer, "output" => "", "pid" => pid } }
    @infos = Hash::new { |hash,k| hash[k] = { "host_name" => host, "pid" => pid, "output" => "" } }

    @at_output_blocks.push lambda { |r,p,l,c,h,e,t|
      rank = r
      pid = p
      line = l
      command = c
      host = h
      eol = e
      type = t
      @hosts[rank]["commands"][pid][type] += line+eol
    }
    
    @command_line_output = "output=\"1:\".length(\"$rank\").\":$rank\".length(\"$pid\").\":$pid\".length(\"$line\").\":$line\".length(\"$command\").\":$command\".length(\"$host\").\":$host\".length(\"$eol\").\":$eol\".length(\"$type\").\":$type\""

    @at_error_blocks.push lambda { |r,p,l,c,h,e,t|
      rank = r
      pid = p
      line = l
      command = c
      host = h
      eol = e
      type = t
      @hosts[rank]["commands"][pid][type] += line+eol
    }

    @command_line_error = "error=\"2:\".length(\"$rank\").\":$rank\".length(\"$pid\").\":$pid\".length(\"$line\").\":$line\".length(\"$command\").\":$command\".length(\"$host\").\":$host\".length(\"$eol\").\":$eol\".length(\"$type\").\":$type\""

    @at_status_blocks.push lambda { |r,p,l,c,h,t,s_d,e_d|
      rank = r
      pid = p
      line = l
      command = c
      host = h
      type = t
      start_date = s_d
      stop_date = e_d
      @hosts[rank]["commands"][pid][type] = line
      @hosts[rank]["commands"][pid]["start_date"] = Time::at(start_date.to_f)
      @hosts[rank]["commands"][pid]["stop_date"] = Time::at(stop_date.to_f)
    }

    @command_line_status = "status=\"3:\".length(\"$rank\").\":$rank\".length(\"$pid\").\":$pid\".length(\"$line\").\":$line\".length(\"$command\").\":$command\".length(\"$host\").\":$host\".length(\"$type\").\":$type\".length(\"$start_date\").\":$start_date\".length(\"$stop_date\").\":$stop_date\""

    @at_info_blocks.push lambda { |p,l,e,h|
      pid = p
      line = l
      eol = e
      host = h
      key = host+"_"+pid
      @infos[key]["output"] += line+eol
    }

    @command_line_info = "info=\"4:\".length(\"$pid\").\":$pid\".length(\"$line\").\":$line\".length(\"$eol\").\":$eol\".length(\"$host\").\":$host\""

    @at_connector_blocks.push lambda { |p,h,pe,l,e|
      pid = p
      host = h
      peer = pe
      line = l
      eol = e
      key = host+"_"+pid
      @connectors[key]["output"] += line+eol
    }

    @command_line_connector = "connector=\"5:\".length(\"$pid\").\":$pid\".length(\"$host\").\":$host\".length(\"$peer\").\":$peer\".length(\"$line\").\":$line\".length(\"$eol\").\":$eol\""

    @at_taktuk_blocks.push lambda { |p,h,le,pa,l_n,l,e|
      pid = p
      host = h
      level_name = le
      package = pa
      line_number = l_n
      line = l
      eol = e
      error = { "host_name" => host, "pid" => pid, "level_name" => level_name, "package" => package, "line_number" => line_number, "description" => line+eol }
      @errors.push(error)
    }

    @command_line_taktuk = "taktuk=\"6:\".length(\"$pid\").\":$pid\".length(\"$host\").\":$host\".length(\"$level_name\").\":$level_name\".length(\"$package\").\":$package\".length(\"$line_number\").\":$line_number\".length(\"$line\").\":$line\".length(\"$eol\").\":$eol\""
    @command_line_state = "state=\"\""

    @cmd = "taktuk"
  end

  def at_connector (&block)
    @at_connector_blocks.push( block )
  end

  def at_error (&block)
    @at_error_blocks.push( block )
  end

  def at_output (&block)
    @at_output_blocks.push( block )
  end

  def at_status (&block)
    @at_status_blocks.push( block )
  end

  def at_taktuk (&block)
    @at_taktuk_blocks.push( block )
  end

  def at_exit (&block)
    @at_exit_blocks.push( block )
  end
  
  def run
    @pid = fork do
      @stdin.close
      @stdout.close
      @stderr.close
      @mystdout.sync = true
      @mystderr.sync = true
      STDIN.reopen(@mystdin)
      STDOUT.reopen(@mystdout)
      STDERR.reopen(@mystderr)
      exec(@cmd,"-R", "taktuk=1", "-o",@command_line_output,"-o",@command_line_error,"-o",@command_line_status,"-o",@command_line_info,"-o",@command_line_connector,"-o",@command_line_taktuk,"-o",@command_line_state,*@argv)
    end
    @mystdin.close
    @mystdout.close
    @mystderr.close

    @stdin.sync
    @stdin.close
    
    while s = @stdout.gets(":") do
      arr = Array::new
      chan = @channels[s.chomp(":")]
      chan[0].times {
        length = @stdout.gets(":").chomp(":").to_i
        arr.push(@stdout.read(length))
      }
      chan[1].each { |b| b.call( *arr ) }
    end
    
    @at_exit_blocks.each { |b|
      b.call
    }
    Process.waitpid(@pid)
  end

end
