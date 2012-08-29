require 'rubygems'
require 'test/unit'
require 'mocha'
require 'mocha_patch'
require 'automata_test_case'

class TestMacrostep < Test::Unit::TestCase
  include AutomataTestCase

  def test_success
    Workflow.any_instance.stubs(:tasks).returns([
      [ :Macro1 ],
      [ :Macro2 ]
    ])
    Macro1.any_instance.stubs(:tasks).returns([ [ :success ] ])
    Microstep.any_instance.stubs(:success).once.returns(true)
    Macro2.any_instance.stubs(:tasks).returns([ [ :end ] ])
    Microstep.any_instance.stubs(:end).once.returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.start

    assert_same(workflow.nodes_ok,@nodeset)
  end

  def test_fail
    Workflow.any_instance.stubs(:tasks).returns([
      [ :Macro1 ],
      [ :Macro2 ]
    ])
    Macro1.any_instance.stubs(:tasks).returns([ [ :fail ] ])
    Microstep.any_instance.stubs(:fail).once.returns(false)
    Macro2.any_instance.stubs(:tasks).returns([ [ :success ] ])
    Microstep.any_instance.stubs(:success).never

    workflow = Workflow.new(@nodeset)
    workflow.start

    assert_same(workflow.nodes_ko,@nodeset)
  end

  def test_timeouts
    Workflow.any_instance.stubs(:tasks).returns([ [ :Macro1 ] ])
    Macro1.any_instance.stubs(:tasks).returns([
      [ :success ],
      [ :success ]
    ])
    Microstep.any_instance.stubs(:success).twice.lasts(0,2).returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro1 => {
        :timeout => 1,
      }
    })
    workflow.start

    assert_same(workflow.nodes_ko,@nodeset)
  end

  def test_raise
  end

  def test_retries
    Workflow.any_instance.stubs(:tasks).returns([ [ :Macro1 ] ])
    Macro1.any_instance.stubs(:tasks).returns([ [ :success ] ])
    Microstep.any_instance.stubs(:success).times(3).lasts(2,0,0).returns(true,false,true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro1 => {
        :timeout => 1,
        :retries => 2,
      }
    })
    workflow.start

    assert_same(workflow.nodes_ok,@nodeset)
  end

  def test_fallback
    Workflow.any_instance.stubs(:tasks).returns([
      [
        [ :Macro1 ],
        [ :Macro2 ],
        [ :Macro3 ]
      ],
      [ :Macro4 ]
    ])
    Macro1.any_instance.stubs(:tasks).returns([ [ :fail ] ])
    Macro2.any_instance.stubs(:tasks).returns([ [ :timeout ] ])
    Macro3.any_instance.stubs(:tasks).returns([ [ :success ] ])
    Macro4.any_instance.stubs(:tasks).returns([ [ :success ] ])

    Microstep.any_instance.stubs(:success).twice.returns(true)
    Microstep.any_instance.stubs(:fail).once.returns(false)
    Microstep.any_instance.stubs(:timeout).once.lasts(2).returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro2 => {
        :timeout => 1
      }
    })
    workflow.start

    assert_same(workflow.nodes_ok,@nodeset)
  end

  def test_raisable
  end
end
