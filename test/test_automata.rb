$:.unshift File.join(File.dirname(__FILE__), '..', 'src','lib')

require 'rubygems'
require 'test/unit'
require 'mocha'
require 'mocha/standalone'
require 'mocha_patch'
require 'pp'

require 'automata'
require 'nodes'


class Microstep
  alias_method :old_run, :run

  def nodes_to_raise()
  end

  def run()
    status,nodes,doraise = nodes_to_raise()
    if status
      if status == :OK
        nodeset = @nodes_ok
      else
        nodeset = @nodes_ko
      end

      (nodes||@nodes).set.each do |node|
        nodeset.push(node)
      end

      if doraise
        raise_nodes(nodeset,status)
        if status == :OK
          @nodes.linked_copy(@nodes_ko)
        else
          @nodes.linked_copy(@nodes_ok)
        end
      end
    end
    return old_run()
  end
end

class TestAutomata < Test::Unit::TestCase
  #include Mocha::Standalone
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
  end

  def teardown
    #mocha_teardown
  end

  def define(name,superclass)
    Object.const_set(name.to_s, Class.new(superclass))
  end

  def test_fail
    define(:Macro1,Macrostep)
    define(:Macro2,Macrostep)
    define(:Micro1,Microstep)
    define(:Micro2,Microstep)

    half = Nodes::NodeSet.new
    (@nodeset.set.size/2).times do |i|
      half.push(@nodeset.set[i])
    end

    Workflow.any_instance.stubs(:tasks).returns(
      [
        [ :Macro1 ],
        [ :Macro2 ]
      ]
    )

    Macro1.any_instance.stubs(:microclass).returns(Micro1)
    Macro1.any_instance.stubs(:tasks).returns(
      [
        [ :success ],
        [ :fail ],
        [ :success ]
      ]
    )

    Macro2.any_instance.stubs(:microclass).returns(Micro2)
    Macro2.any_instance.stubs(:tasks).returns(
      [
        [ :success ]
      ]
    )

    Micro1.any_instance.stubs(:tasks).returns(
      [
        [ :success ],
        [ :fail ],
        [ :success ]
      ]
    )
    Micro1.any_instance.stubs(:nodes_to_raise).returns(
      [:OK],
      [:KO,half,true],
      [:OK]
    )
    Micro1.any_instance.stubs(:ms_success).twice.lasts(2).returns(true)
    Micro1.any_instance.stubs(:ms_fail).once.lasts(2).returns(true)

    Micro2.any_instance.stubs(:tasks).returns(
      [
        [ :success ],
      ]
    )
    Micro2.any_instance.stubs(:nodes_to_raise).returns(
      [:OK]
    )
    Micro2.any_instance.stubs(:ms_success).once.lasts(4).returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro1 => {
        :timeout => 20,
        :config => {
          :success => {
            :timeout => 2
          }
        }
      }
    })
    workflow.start

    assert_same(workflow.nodes_ko,half)
  end
end
