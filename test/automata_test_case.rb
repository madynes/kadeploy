$:.unshift File.join(File.dirname(__FILE__), '..', 'src','lib')
require 'nodes'
require 'automata'

class Microstep
  @@context = {}

  def method_missing(meth, *args)
    if meth.to_s =~ /^ms_.*$/
      send(:microtest,meth,*args)
      send(meth.to_s.gsub(/^ms_/,'').to_sym)
    else
      super
    end
  end

  def self.reset_context()
    @@context = {}
  end

  def microtest(meth,opts = {})
    raised = []
    if opts[:raise]
      @@context[:raises] = {} unless @@context[:raises]
      @@context[:raises][meth] = [] unless @@context[:raises][meth]

      opts[:raise] = [ opts[:raise] ] unless opts[:raise].is_a?(Array)

      opts[:raise].each_index do |i|
        @@context[:raises][meth][i] = 0 unless @@context[:raises][meth][i]

        r = opts[:raise][i]

        if !r[:times] or (@@context[:raises][meth][i] < r[:times])
          @@context[:raises][meth][i] += 1

          sleep(r[:wait_before]) if r[:wait_before]

          nodeset = (r[:status] == :OK ? @nodes_ok : @nodes_ko)
          r[:nodeset].set.each do |node|
            nodeset.push(node)
            raised.push(node)
          end

          raise_nodes(nodeset,r[:status])

          sleep(r[:wait_after]) if r[:wait_after]
        end
      end
    end

    opts[:nodes_ok].linked_copy(@nodes_ok) if opts[:nodes_ok]
    opts[:nodes_ko].linked_copy(@nodes_ko) if opts[:nodes_ko]

    if opts[:default_ko]
      @nodes.linked_copy(@nodes_ko)
    elsif opts[:default_ok] != false
      @nodes.linked_copy(@nodes_ok)
    end
  end
end

module AutomataTestCase
  def setup
    @nodeset = Nodes::NodeSet.new(0)
    16.times do |i|
      @nodeset.push(
        Nodes::Node.new(
          "test-#{i}.domain.tld",
          "10.0.0.#{i}",
          'test',
          nil
        )
      )
    end

    def @nodeset.[](range)
      ret = Nodes::NodeSet.new(@id)
      @set[range].each do |n|
        ret.push(n)
      end
      ret
    end

    def @nodeset.half()
      self[0..@set.size/2]
    end

    define(:Macro1,Macrostep)
    define(:Macro2,Macrostep)
    define(:Macro3,Macrostep)
    define(:Macro4,Macrostep)

    define(:Micro1,Microstep)
    define(:Micro2,Microstep)
    define(:Micro3,Microstep)
    define(:Micro4,Microstep)
  end

  def teardown
    undefine(:Macro1)
    undefine(:Macro2)
    undefine(:Macro3)
    undefine(:Macro4)

    undefine(:Micro1)
    undefine(:Micro2)
    undefine(:Micro3)
    undefine(:Micro4)

    Microstep.reset_context
  end

  def define(name,superclass)
    Object.const_set(name.to_s, Class.new(superclass))
  end

  def undefine(name)
    Object.send(:remove_const, name.to_s)
  end
end
