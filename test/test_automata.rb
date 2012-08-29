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
  def method_missing(meth, *args)
    if meth.to_s =~ /^ms_.*$/
      send(:microtest,*args)
      send(meth.to_s.gsub(/^ms_/,'').to_sym)
    else
      super
    end
  end

  def microtest(opts = {})
    if opts[:raise]
      opts[:raise] = [ opts[:raise] ] unless opts[:raise].is_a?(Array)
      opts[:raise].each do |r|
        sleep(r[:wait_before]) if r[:wait_before]

        nodeset = (r[:status] == :OK ? @nodes_ok : @nodes_ko)
        r[:nodeset].set.each do |node|
          nodeset.push(node)
        end

        raise_nodes(nodeset,r[:status])

        sleep(r[:wait_after]) if r[:wait_after]
      end
    end

    if opts[:default_ko]
      @nodes.linked_copy(@nodes_ko)
    elsif opts[:default_ok] != false
      @nodes.linked_copy(@nodes_ok)
    end
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
  end

  def define(name,superclass)
    Object.const_set(name.to_s, Class.new(superclass))
  end

  def undefine(name)
    Object.send(:remove_const, name.to_s)
  end

  def test_fail
    half = @nodeset.half

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
        [ :fail_half, {
          :raise => {
            :nodeset => @nodeset.half,
            :status => :KO
          }
        }],
        [ :success ]
      ]
    )
    Micro1.any_instance.stubs(:success).times(3).lasts(3,2).returns(true,true,true)
    Micro1.any_instance.stubs(:fail_half).once.lasts(2).returns(true)

    Macro2.any_instance.stubs(:microclass).returns(Micro2)
    Macro2.any_instance.stubs(:tasks).returns(
      [
        [ :success ],
      ]
    )
    Micro2.any_instance.stubs(:success).once.lasts(4).returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro1 => {
        :timeout => 20,
        :config => {
          :success => {
            :timeout => 2,
            :retries => 1
          }
        }
      }
    })
    workflow.start

    assert_same(workflow.nodes_ko,@nodeset.half)
  end
end
