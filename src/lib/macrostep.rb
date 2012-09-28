# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadelpoy libs
require 'automata'
require 'debug'

class Macrostep < Automata::TaskedTaskManager
  attr_reader :output, :logger
  include Printer

  def initialize(name, idx, subidx, nodes, manager_queue, output, logger, context = {}, params = [])
    super(name,idx,subidx,nodes,manager_queue,context,params)
    @output = output
    @logger = logger
  end

  def microclass
    Microstep
  end

  def create_task(idx,subidx,nodes,context)
    taskval = get_task(idx,subidx)

    microclass().new(
      taskval[0],
      idx,
      subidx,
      nodes,
      @queue,
      @output,
      context,
      taskval[1..-1]
    )
  end

  def break!(task,nodeset)
    #debug(4,"<<< Raising BRK nodes #{nodeset.to_s_fold} from #{self.class.name}") if @config[task.name][:raisable]
    debug(1,"End of step #{self.class.name} for BRK nodes #{nodeset.to_s_fold}")
  end

  def success!(task,nodeset)
    #debug(4,"<<< Raising OK nodes #{nodeset.to_s_fold} from #{self.class.name}") if @config[task.name][:raisable]
    debug(1,"End of step #{self.class.name} for OK nodes #{nodeset.to_s_fold}")
  end

  def fail!(task,nodeset)
    #debug(4,"<<< Raising KO nodes #{nodeset.to_s_fold} from #{self.class.name}") if @config[task.name][:raisable]
    debug(1,"End of step #{self.class.name} for KO nodes #{nodeset.to_s_fold}")
  end

  def timeout!(task)
    debug(1,
      "Timeout in [#{task.name}] before the end of the step, "\
      "let's kill the instance"
    )
    task.nodes.set_error_msg("Timeout in the #{task.name} step")
    nodes.set.each do |node|
      node.state = "KO"
      context[:config].set_node_state(node.hostname, "", "", "ko")
    end
  end

  def split!(ns,ns1,ns2)
    debug(1,"Nodeset(#{ns.id}) split into :")
    debug(1,"  Nodeset(#{ns1.id}): #{ns1.to_s_fold}")
    debug(1,"  Nodeset(#{ns2.id}): #{ns2.to_s_fold}")
  end

  def start!()
    debug(1,
      "Performing a #{self.class.name} step on the nodes #{nodes.to_s_fold}"
    )
    log("step#{idx+1}", self.class.name,nodes)
    log("timeout_step#{idx+1}", context[:local][:timeout] || 0, nodes)
  end

  def done!()
    log("step#{idx+1}_duration", context[:local][:duration], nodes)
  end
end
