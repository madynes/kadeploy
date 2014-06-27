module Kadeploy

require 'socket'
require 'pty'

module Kaconsole
  def console_init_exec_context(ret)
    ret.config = nil
    ret
  end

  def console_init_info(cexec)
    {
      :wid => uuid(API.wid_prefix(:console)),
      :user => cexec.user,
      :start_time => Time.now,
      :end_time => nil,
      :done => false,
      :thread => nil,
      :freed => false,
      :resources => {},
      :bindings => [],
      :node => cexec.node,
      :nodelist => cexec.nodelist, # compatibility with other workflow classes
      :sock => nil,
      :uri => nil,
      :client => nil,
      :attached => Mutex.new,
    }
  end

  def console_init_resources(cexec)
    bind(:console,cexec.info,'error','/error')
  end

  def console_free_exec_context(context)
    context = free_exec_context(context)
    if context.config
      context.config.free
      context.config = nil
    end
    context.node = nil if context.node
    context.nodelist = nil if context.nodelist
    context
  end

  def console_prepare(params,operation,context)
    context = console_init_exec_context(context)
    operation ||= :get

    case operation
    when :create
      context.config = duplicate_config()

      parse_params(params) do |p|
        context.node = p.parse('node',String,:type=>:node,:mandatory=>true)
        context.nodelist = [context.node.hostname.dup]
      end

      kaerror(APIError::INVALID_RIGHTS) \
        unless context.rights.granted?(context.user,context.node,'')
    when :get
    when :delete
    else
      raise
    end

    context.info = console_init_info(context)

    if operation == :create
      error_forbidden!("This feature is disabled: no console command is given in configuration file.") unless context.config.clusters[context.info[:node].cluster].cmd_console
    end

    context
  end

  def console_rights?(cexec,operation,names,wid=nil,*args)
    case operation
    when :create
    when :get
      if wid and names
        workflow_get(:console,wid) do |info|
          return (cexec.almighty_users.include?(cexec.user) \
            or cexec.user == info[:user])
        end
      end
    when :delete
      return false unless wid
      workflow_get(:console,wid) do |info|
        return (cexec.almighty_users.include?(cexec.user) \
          or cexec.user == info[:user])
      end
    else
      raise
    end

    return true
  end

  def console_create(cexec)
    info = cexec.info
    workflow_create(:console,info[:wid],info,:console)
    console_init_resources(cexec)

    node = info[:node]
    cmd = node.cmd.console || cexec.config.clusters[node.cluster].cmd_console
    cmd = Nodes::NodeCmd.generate(cmd.dup,node)


    info[:sock] = TCPServer.new(0)
    info[:resources][:console] = "tcp://#{Socket.gethostname}:#{info[:sock].addr[1]}"

    info[:thread] = Thread.new do
      begin
        loop do
          sock = info[:sock].accept
          if info[:attached].locked?
            sock.syswrite("[Kaconsole] console already attached\n")
            sock.close
          else
            info[:client] = console_client_run(sock,info[:attached],cmd)
          end
        end
      ensure
        info[:sock].close if info[:sock]
        info[:end_time] = Time.now
      end
    end

    { :wid => info[:wid], :resources => info[:resources] }
  end

  def console_get(cexec,wid=nil)
    get_status = Proc.new do |info|
      ret = {
        :id => info[:wid],
        :user => info[:user],
        :node => info[:nodelist].first,
      }

      if info[:thread].alive?
        ret[:error] = false
        if cexec.almighty_users.include?(cexec.user) or cexec.user == info[:user]
          ret[:attached] = info[:attached].locked?
          ret[:console_uri] = info[:resources][:console]
        end
      else
        ret[:error] = true
        #info[:done] = true
        console_kill(info)
        console_free(info)
      end

      ret[:time] = ((info[:end_time]||Time.now) - info[:start_time]).round(2)

      ret
    end

    if wid
      workflow_get(:console,wid) do |info|
        get_status.call(info)
      end
    else
      ret = []
      workflow_list(:console) do |info|
        ret << get_status.call(info)
      end
      ret
    end
  end

  def console_delete(cexec,wid)
    workflow_delete(:console,wid) do |info|
      console_delete!(cexec,info)
    end
  end

  def console_delete!(cexec,info)
    console_kill(info)
    console_free(info)

    { :wid => info[:wid] }
  end

  def console_kill(info)
    unless info[:freed]
      info[:thread].kill if info[:thread].alive?
      console_client_kill(info[:client])
    end
  end

  def console_free(info)
    unless info[:freed]
      info[:node].free
      info.delete(:node)

      info.delete(:sock)
      info.delete(:uri)
      info.delete(:client)
      info.delete(:attached)

      info[:freed] = true
    end
  end

  def console_get_error(cexec,wid)
    workflow_get(:console,wid) do |info|
      break if info[:thread].alive?
      begin
        info[:thread].join
        nil
      rescue Exception => e
        console_free(info)
        raise e
      end
    end
  end

  def console_client_run(sock,lock,cmd)
    Thread.new do
    lock.synchronize do
      begin
        Thread.current[:kill] = Mutex.new
        Thread.current[:sock] = sock.clone
        Thread.current[:pid] = nil
        Thread.current[:threads] = []

        sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

        PTY.spawn(cmd) do |r,w,pid|
          Thread.current[:pid] = pid
          done = false

          # From process to network
          Thread.current[:threads] << Thread.new do
            buf = String.new
            until done do
              begin
                r.sysread(4096,buf)
              rescue Errno::EIO
                sock.close_write
                break
              end
              sock.syswrite(buf)
            end
          end

          # From network to process
          Thread.current[:threads] << Thread.new do
            c = String.new
            until done do
              begin
                sock.sysread(1,c)
                w.syswrite(c)
              rescue EOFError, Errno::ECONNRESET
                sock.close_read
                done = true
              end
            end
          end

          ret = nil
          sleep 1 while !done and !(ret = PTY.check(pid))
          done = true

          unless ret # client disconnection
            Thread.current[:kill].synchronize do # provide conflict with DELETE
              if Thread.current[:pid]
                begin
                  Execute.kill_recursive(pid)
                rescue Errno::ESRCH
                end
                PTY.check(pid)
                Thread.current[:pid] = nil
              end
            end
          else
            Thread.current[:pid] = nil
          end
          r.close
          w.close

          Thread.current[:threads].each do |thr|
            thr.kill if thr.alive?
            thr.join
          end
          Thread.current[:threads].clear
          Thread.current[:threads] = nil
        end
      ensure
        sock.close unless sock.closed?
        Thread.current[:sock] = nil
      end
    end
    end
  end

  def console_client_kill(client)
    if client and client.alive?
      sleep 1 unless client[:sock]

      if client[:sock]
        begin
          client[:sock].syswrite("\n[Kaconsole] client killed\n")
        rescue
        end
      end

      sleep 1 unless client[:pid]

      client[:kill].synchronize do
        if client[:pid]
          begin
            Execute.kill_recursive(client[:pid])
          rescue Errno::ESRCH
          end
          sleep 2 # wait for the thread to clean itself
          if client[:pid]
            PTY.check(client[:pid])
            client[:pid] = nil
          end
        end
      end

      client.kill if client.alive?
      client.join

      if client[:threads]
        client[:threads].each do |thr|
          thr.kill if thr.alive?
          thr.join
        end
      end

      if client[:sock] and !client[:sock].closed?
        client[:sock].close
        client[:sock] = nil
      end
    end
  end
end

end
