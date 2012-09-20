$:.unshift File.join(File.dirname(__FILE__), '..', 'src','lib')

require 'automata'
require 'nodes'


class Microstep < QueueTask
  def raise_nodes(nodeset,status)
    super(nodeset,status)
  end

  def ms_nothing()
  end

  def ms_only_half(status)
    nodes = nil
    if status == 'OK'
      nodes = @nodes_ok
    else
      nodes = @nodes_ko
    end

    (@nodes.set.size / 2).times do |i|
      nodes.push(@nodes.set[i])
    end

    return true
  end

  def ms_success()
    @nodes.linked_copy(@nodes_ok)
    return true
  end

  def ms_fail()
    @nodes.linked_copy(@nodes_ko)
    return false
  end

  def ms_split_half()
    @nodes.set.size.times do |i|
      if (i % 2) == 0
        @nodes_ok.push(@nodes.set[i])
      else
        @nodes_ko.push(@nodes.set[i])
      end
    end
    return true
  end

  def ms_wait(time)
    sleep(time)
    @nodes.linked_copy(@nodes_ok)
    return true
  end

  def ms_wait_raise_half(time,status)
    sleep(time/2)

    if status == 'OK'
      (@nodes.set.size/2).times do |i|
        @nodes_ok.push(@nodes.set[i])
      end
      raise_nodes(@nodes_ok,:OK)
    else
      (@nodes.set.size/2).times do |i|
        @nodes_ko.push(@nodes.set[i])
      end
      raise_nodes(@nodes_ko,:KO)
    end

    sleep(time/2)

    if status == 'OK'
      @nodes.linked_copy(@nodes_ko)
    else
      @nodes.linked_copy(@nodes_ok)
    end
    return true
  end

  def method_missing(meth, *args)
    debug("#{meth}")

    if meth.to_s =~ /^ms_.*$/
      super
    else
      send("ms_#{meth}".to_sym,*args)
    end
  end
end

class Workflow < TaskManager
  def load_config()
    super()

    conf_task(
      :SetDeployEnvFail,
      {
        :timeout => 4,
        :retries => 2,
      }
    )
    conf_task(:SetDeployEnvTest, { :timeout => 9 })
    conf_task(:BroadcastEnvTest, { :timeout => 10 })
  end

  def tasks()
    [
      [
        [ :SetDeployEnvFail ],
        [ :SetDeployEnvTest ],
        [ :SetDeployEnvTestFallback ],
      ],
      [ :BroadcastEnvTest ],
      [ :BootNewEnvTest ]
    ]
  end
end

class Macrostep < TaskedTaskManager
  def load_config()
    super()
    conf_task(:wait,{ :timeout => 3 })
  end
end

class SetDeployEnvFail < Macrostep
  def load_config()
    super()
  end

  def tasks()
    [
      [ :fail ]
    ]
  end
end


class SetDeployEnvTest < Macrostep
  def load_config()
    super()

    conf_task(:split_half,{ :raisable => false })
  end

  def tasks()
    [
      [ :success ],
      [
        [ :wait, 4 ],
        [ :wait, 1 ],
      ],
      [ :split_half ],
      [ :wait, 1 ],
      [ :wait_raise_half, 2, 'KO' ],
      [ :wait, 1 ],
      [ :success ],
    ]
  end
end

class SetDeployEnvTestFallback < Macrostep
  def load_config()
    super()
  end

  def tasks()
    [
      [ :success ],
      [ :wait, 1 ],
      [ :split_half ],
    ]
  end
end

class BroadcastEnvTest < Macrostep
  def load_config()
    super()
  end

  def tasks()
    [
      [ :wait_raise_half, 8, 'OK' ]
    ]
  end
end

class BootNewEnvTest < Macrostep
  def load_config()
    super()
  end

  def tasks()
    [
      [
        [ :fail ],
        [ :wait, 2 ]
      ],
      [ :success ],
      [ :only_half, 'OK' ],
      [
        [ :nothing ],
        [ :success ],
      ]
    ]
  end
end



nodeset = Nodes::NodeSet.new(0)
16.times do |i|
  nodeset.push(
    Nodes::Node.new(
      "test-#{i}.domain.tld",
      "10.0.0.#{i}",
      'test',
      nil
    )
  )
end

w = Workflow.new(nodeset)
w.start()

puts "OK: #{w.nodes_ok.to_s_fold}"
puts "KO: #{w.nodes_ko.to_s_fold}"
