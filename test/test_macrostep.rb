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

    assert_same(workflow.nodes,@nodeset)
    assert_same(workflow.nodes_done,@nodeset)
    assert_same(workflow.nodes_ok,@nodeset)
    assert(workflow.nodes_ko.empty?)
  end

  def test_fail
    Workflow.any_instance.stubs(:tasks).returns([
      [ :Macro1 ],
      [ :Macro2 ]
    ])
    Macro1.any_instance.stubs(:tasks).returns([ [ :fail ] ])
    Microstep.any_instance.stubs(:fail).once.returns(false)
    Macro2.any_instance.stubs(:tasks).returns([ [ :never ] ])
    Microstep.any_instance.stubs(:success).never

    workflow = Workflow.new(@nodeset)
    workflow.start

    assert_same(workflow.nodes,@nodeset)
    assert_same(workflow.nodes_done,@nodeset)
    assert_same(workflow.nodes_ko,@nodeset)
    assert(workflow.nodes_ok.empty?)
  end

  def test_timeouts
    Workflow.any_instance.stubs(:tasks).returns([ [ :Macro1 ] ])
    Macro1.any_instance.stubs(:tasks).returns([
      [ :success ],
      [ :never ]
    ])
    Microstep.any_instance.stubs(:success).once.lasts(2).returns(true)
    Microstep.any_instance.stubs(:never).never

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro1 => {
        :timeout => 1,
      }
    })
    workflow.start

    assert_same(workflow.nodes,@nodeset)
    assert_same(workflow.nodes_done,@nodeset)
    assert_same(workflow.nodes_ko,@nodeset)
    assert(workflow.nodes_ok.empty?)
  end

  def test_raise
    define(:Macro5,Macrostep)
    Workflow.any_instance.stubs(:tasks).returns([
      [ :Macro1 ],
      [ :Macro2 ],
      [ :Macro3 ],
      [ :Macro4 ],
      [ :Macro5 ]
    ])
    Macro1.any_instance.stubs(:tasks).returns([
      [ :raise_ko, {
        :raise => {
          :nodeset => @nodeset[0..3],
          :status => :KO
        }
      }]
    ])
    Macro2.any_instance.stubs(:tasks).returns([
      [ :raise_ok, {
        :raise => {
          :nodeset => @nodeset[4..8],
          :wait_after => 2,
          :status => :OK
        }
      }]
    ])
    Macro3.any_instance.stubs(:tasks).returns([
      [ :timeout ]
    ])
    Macro4.any_instance.stubs(:tasks).returns([
      [ :raise_twice, {
        :raise => [
          {
            :nodeset => @nodeset[9..10],
            :wait_after => 2,
            :status => :OK
          },
          {
            :nodeset => @nodeset[11..12],
            :status => :OK
          }
        ]
      }],
    ])
    Macro5.any_instance.stubs(:tasks).returns([
      [ :success ]
    ])
    Microstep.any_instance.stubs(:raise_ko).once.returns(true)
    Microstep.any_instance.stubs(:raise_ok).once.returns(true)
    Microstep.any_instance.stubs(:timeout).twice.lasts(2,0).returns(true)
    Microstep.any_instance.stubs(:raise_twice).once.returns(true)
    Microstep.any_instance.stubs(:success).times(3).returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro3 => {
        :timeout => 1
      }
    })
    workflow.start

    assert_same(workflow.nodes,@nodeset)
    assert_same(workflow.nodes_done,@nodeset)
    assert_same(workflow.nodes_ko,@nodeset[0..8])
    assert_same(workflow.nodes_ok,@nodeset[9..15])

    undefine(:Macro5)
  end

  def test_retries
    define(:MacroSuccess,Macrostep)
    define(:MacroFail,Macrostep)
    define(:MacroNever,Macrostep)
    define(:MacroTimeout,Macrostep)
    define(:MacroRaise,Macrostep)
    Workflow.any_instance.stubs(:tasks).returns([
      [ :MacroTimeout ],
      [ :MacroFail ],
      [ :MacroRaise ],
      [
        [ :MacroSuccess ],
        [ :MacroNever ]
      ]
    ])
    MacroTimeout.any_instance.stubs(:tasks).returns([ [ :timeout ] ])
    MacroFail.any_instance.stubs(:tasks).returns([ [ :fail ] ])
    MacroRaise.any_instance.stubs(:tasks).returns([
      [ :raise, {
        :raise => {
          :nodeset => @nodeset.half,
          :status => :KO,
          :times => 1
        }
      }]
    ])
    MacroSuccess.any_instance.stubs(:tasks).returns([ [ :success ] ])
    MacroNever.any_instance.stubs(:tasks).returns([ [ :never ] ])
    Microstep.any_instance.stubs(:timeout).twice.lasts(2,0).returns(true)
    Microstep.any_instance.stubs(:fail).twice.returns(false,true)
    Microstep.any_instance.stubs(:raise).twice.lasts(1).returns(true)
    Microstep.any_instance.stubs(:success).twice.returns(true)
    Microstep.any_instance.stubs(:never).never

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :MacroTimeout => {
        :timeout => 1,
        :retries => 1,
      },
      :MacroFail => {
        :retries => 1,
      },
      :MacroRaise => {
        :retries => 1,
      },
      :MacroSuccess => {
        :retries => 1,
      },
    })
    workflow.start

    assert_same(workflow.nodes,@nodeset)
    assert_same(workflow.nodes_done,@nodeset)
    assert_same(workflow.nodes_ok,@nodeset)
    assert(workflow.nodes_ko.empty?)

    undefine(:MacroSuccess)
    undefine(:MacroFail)
    undefine(:MacroNever)
    undefine(:MacroTimeout)
    undefine(:MacroRaise)
  end

  def test_fallback
    define(:MacroSuccess,Macrostep)
    define(:MacroFail,Macrostep)
    define(:MacroNever,Macrostep)
    define(:MacroTimeout,Macrostep)
    define(:MacroRetry,Macrostep)
    define(:MacroRaise,Macrostep)
    define(:MacroEnd,Macrostep)
    Workflow.any_instance.stubs(:tasks).returns([
      [
        [ :MacroSuccess ],
        [ :MacroNever ],
      ],
      [
        [ :MacroFail ],
        [ :MacroTimeout ],
        [ :MacroRetry ],
        [ :MacroSuccess ]
      ],
      [
        [ :MacroRaise ],
        [ :MacroSuccess ],
      ],
      [ :MacroEnd ]
    ])
    MacroSuccess.any_instance.stubs(:tasks).returns([ [ :success ] ])
    MacroNever.any_instance.stubs(:tasks).returns([ [ :never ] ])
    MacroFail.any_instance.stubs(:tasks).returns([ [ :fail ] ])
    MacroTimeout.any_instance.stubs(:tasks).returns([ [ :timeout ] ])
    MacroRetry.any_instance.stubs(:tasks).returns([ [ :retry ] ])
    MacroRaise.any_instance.stubs(:tasks).returns([
      [ :raise, {
          :raise => {
            :nodeset => @nodeset.half,
            :status => :KO,
          }
      }]
    ])
    MacroEnd.any_instance.stubs(:tasks).returns([ [ :end ] ])

    Microstep.any_instance.stubs(:never).never
    Microstep.any_instance.stubs(:fail).once.returns(false)
    Microstep.any_instance.stubs(:timeout).once.lasts(2).returns(true)
    Microstep.any_instance.stubs(:retry).twice.returns(false)
    Microstep.any_instance.stubs(:raise).once.returns(true)
    Microstep.any_instance.stubs(:success).times(3).returns(true)
    Microstep.any_instance.stubs(:end).twice.returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :MacroTimeout => {
        :timeout => 1
      },
      :MacroRetry => {
        :retries => 1
      }
    })
    workflow.start

    assert_same(workflow.nodes,@nodeset)
    assert_same(workflow.nodes_done,@nodeset)
    assert_same(workflow.nodes_ok,@nodeset)
    assert(workflow.nodes_ko.empty?)

    undefine(:MacroSuccess)
    undefine(:MacroFail)
    undefine(:MacroNever)
    undefine(:MacroTimeout)
    undefine(:MacroRetry)
    undefine(:MacroRaise)
    undefine(:MacroEnd)
  end

  def test_raisable
    Workflow.any_instance.stubs(:tasks).returns([
      [ :Macro1 ],
      [ :Macro2 ],
      [ :Macro3 ],
      [ :Macro4 ]
    ])
    Macro1.any_instance.stubs(:tasks).returns([
      [ :raise, {
          :raise => {
            :nodeset => @nodeset.half,
            :status => :OK,
          }
      }]
    ])
    Macro2.any_instance.stubs(:tasks).returns([ [ :success ] ])
    Macro3.any_instance.stubs(:tasks).returns([
      [ :raise, {
          :raise => {
            :nodeset => @nodeset.half,
            :status => :OK,
            :wait_after => 2,
          }
      }]
    ])
    Macro4.any_instance.stubs(:tasks).returns([ [ :end ] ])
    Microstep.any_instance.stubs(:raise).twice.returns(true,false)
    Microstep.any_instance.stubs(:success).once.returns(true)
    Microstep.any_instance.stubs(:end).once.returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro1 => {
        :config => {
          :raise => {
            :raisable => false
          }
        }
      },
      :Macro3 => {
        :config => {
          :raise => {
            :raisable => false
          }
        }
      }
    })
    workflow.start

    assert_same(workflow.nodes,@nodeset)
    assert_same(workflow.nodes_done,@nodeset)
    assert_same(workflow.nodes_ok,@nodeset.half)
    assert_same(workflow.nodes_ko,@nodeset.diff(@nodeset.half))
  end

  def test_return
    define(:MacroSuccess,Macrostep)
    define(:MacroNever,Macrostep)
    define(:MacroRetry,Macrostep)
    define(:MacroFallback,Macrostep)
    define(:MacroOnce,Macrostep)
    define(:MacroRaise,Macrostep)
    define(:MacroEnd,Macrostep)
    Workflow.any_instance.stubs(:tasks).returns([
      [
        [ :MacroSuccess ],
        [ :MacroNever ],
      ],
      [ :MacroRetry ],
      [ :MacroRaise ],
      [
        [ :MacroFallback ],
        [ :MacroOnce ],
      ],
      [ :MacroEnd ]
    ])
    MacroSuccess.any_instance.stubs(:tasks).returns([
      [ :success, { :nodes_ok => @nodeset }]
    ])
    MacroNever.any_instance.stubs(:tasks).returns([
      [ :never ]
    ])
    MacroRetry.any_instance.stubs(:tasks).returns([
      [ :retry, { :nodes_ko => @nodeset[0..3] }]
    ])
    MacroRaise.any_instance.stubs(:tasks).returns([
      [ :raise, {
        :raise => {
          :nodeset => @nodeset[9..15],
          :status => :OK,
          :wait_after => 1,
        },
        :nodes_ko => @nodeset[4..8]
      }]
    ])
    MacroFallback.any_instance.stubs(:tasks).returns([
      [ :fallback, { :nodes_ko => @nodeset[9..12] }]
    ])
    MacroOnce.any_instance.stubs(:tasks).returns([
      [ :once, { :nodes_ko => @nodeset[9..10] } ]
    ])
    MacroEnd.any_instance.stubs(:tasks).returns([
      [ :end ]
    ])
    Microstep.any_instance.stubs(:success).once.returns(true)
    Microstep.any_instance.stubs(:never).never
    Microstep.any_instance.stubs(:retry).twice.returns(false,true)
    Microstep.any_instance.stubs(:fallback).once.returns(true)
    Microstep.any_instance.stubs(:once).once.returns(true)
    Microstep.any_instance.stubs(:raise).once.returns(true)
    Microstep.any_instance.stubs(:end).twice.returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :MacroRetry => {
        :config => {
          :retry => {
            :retries => 1,
          },
        }
      },
    })
    workflow.start

    assert_same(workflow.nodes,@nodeset)
    assert_same(workflow.nodes_done,@nodeset)
    assert_same(workflow.nodes_ko,@nodeset[0..10])
    assert_same(workflow.nodes_ok,@nodeset[11..15])

    undefine(:MacroSuccess)
    undefine(:MacroNever)
    undefine(:MacroRetry)
    undefine(:MacroFallback)
    undefine(:MacroOnce)
    undefine(:MacroRaise)
    undefine(:MacroEnd)
  end

  def test_breakpoint
    define(:MacroRaise,Macrostep)
    define(:MacroBreak,Macrostep)
    define(:MacroNever,Macrostep)
    define(:MacroOK,Macrostep)
    define(:MacroKO,Macrostep)

    Workflow.any_instance.stubs(:tasks).returns([
      [
        [ :MacroRaise ],
        [ :MacroBreak ],
        [ :MacroNever ],
      ],
      [ :MacroKO ],
      [
        [ :MacroOK ],
        [ :MacroBreak ],
        [ :MacroNever ],
      ]
    ])
    MacroRaise.any_instance.stubs(:tasks).returns([
      [ :raise, {
        :raise => {
          :nodeset => @nodeset[0..4],
          :status => :KO,
        },
      }]
    ])
    MacroBreak.any_instance.stubs(:tasks).returns([
      [ :breakpoint ]
    ])
    MacroNever.any_instance.stubs(:tasks).returns([
      [ :never ]
    ])
    MacroKO.any_instance.stubs(:tasks).returns([
      [ :raise, {
        :raise => {
          :nodeset => @nodeset[9..12],
          :status => :KO,
        },
      }]
    ])
    MacroOK.any_instance.stubs(:tasks).returns([
      [ :raise, {
        :raise => {
          :nodeset => @nodeset[13..15],
          :status => :OK,
        },
      }]
    ])
    Microstep.any_instance.stubs(:breakpoint).never
    Microstep.any_instance.stubs(:never).never
    Microstep.any_instance.stubs(:raise).times(3).returns(true,true,false)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :MacroBreak => {
        :breakpoint => true
      },
    })
    workflow.start

    assert_same(workflow.nodes,@nodeset)
    assert_same(workflow.nodes_done,@nodeset)
    assert_same(workflow.nodes_brk,@nodeset[0..8])
    assert_same(workflow.nodes_ok,@nodeset[13..15])
    assert_same(workflow.nodes_ko,@nodeset[9..12])

    undefine(:MacroRaise)
    undefine(:MacroBreak)
    undefine(:MacroNever)
    undefine(:MacroOK)
    undefine(:MacroKO)
  end
end
