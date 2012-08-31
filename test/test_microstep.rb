require 'rubygems'
require 'test/unit'
require 'mocha'
require 'mocha_patch'
require 'automata_test_case'


class TestMicrostep < Test::Unit::TestCase
  include AutomataTestCase

  def test_success
    Workflow.any_instance.stubs(:tasks).returns([ [ :Macro1 ] ])
    Macro1.any_instance.stubs(:tasks).returns([
      [ :success ],
      [ :end ]
    ])
    Microstep.any_instance.stubs(:success).once.returns(true)
    Microstep.any_instance.stubs(:end).once.returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.start

    assert_same(workflow.nodes_ok,@nodeset)
  end

  def test_fail
    Workflow.any_instance.stubs(:tasks).returns([ [ :Macro1 ] ])
    Macro1.any_instance.stubs(:tasks).returns([
      [ :fail ],
      [ :never ]
    ])
    Microstep.any_instance.stubs(:fail).once.returns(false)
    Microstep.any_instance.stubs(:never).never

    workflow = Workflow.new(@nodeset)
    workflow.start

    assert_same(workflow.nodes_ko,@nodeset)
  end

  def test_timeouts
    Workflow.any_instance.stubs(:tasks).returns([ [ :Macro1 ] ])
    Macro1.any_instance.stubs(:tasks).returns([ [ :success ] ])
    Microstep.any_instance.stubs(:success).once.lasts(2).returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro1 => {
        :config => {
          :success => {
            :timeout => 1,
          }
        }
      }
    })
    workflow.start

    assert_same(workflow.nodes_ko,@nodeset)
  end

  def test_raise
    Workflow.any_instance.stubs(:tasks).returns([ [ :Macro1 ] ])
    Macro1.any_instance.stubs(:tasks).returns([
      [ :raise_ko, {
        :raise => {
          :nodeset => @nodeset[0..3],
          :status => :KO
        }
      }],
      [ :raise_ok, {
        :raise => {
          :nodeset => @nodeset[4..8],
          :wait_after => 2,
          :status => :OK
        }
      }],
      [ :timeout ],
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
      [ :success ],
    ])
    Microstep.any_instance.stubs(:raise_ko).once.returns(true)
    Microstep.any_instance.stubs(:raise_ok).once.returns(true)
    Microstep.any_instance.stubs(:timeout).twice.lasts(2,0).returns(true)
    Microstep.any_instance.stubs(:raise_twice).once.returns(true)
    Microstep.any_instance.stubs(:success).times(3).returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro1 => {
        :config => {
          :timeout => {
            :timeout => 1,
          },
        }
      }
    })
    workflow.start

    assert_same(workflow.nodes_ok,@nodeset[9..15])
  end

  def test_retries
    Workflow.any_instance.stubs(:tasks).returns([ [ :Macro1 ] ])
    Macro1.any_instance.stubs(:tasks).returns([
      [ :timeout ],
      [ :fail ],
      [ :raise, {
        :raise => {
          :nodeset => @nodeset.half,
          :status => :KO,
          :times => 1
        }
      }],
      [ :success ]
    ])
    Microstep.any_instance.stubs(:timeout).twice.lasts(2,0).returns(true)
    Microstep.any_instance.stubs(:fail).twice.returns(false,true)
    Microstep.any_instance.stubs(:raise).twice.lasts(1).returns(true)
    Microstep.any_instance.stubs(:success).twice.returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro1 => {
        :config => {
          :timeout => {
            :timeout => 1,
            :retries => 1,
          },
          :fail => {
            :retries => 1,
          },
          :raise => {
            :retries => 1,
          }
        }
      }
    })
    workflow.start

    assert_same(workflow.nodes_ok,@nodeset)
  end

  def test_fallback
    Workflow.any_instance.stubs(:tasks).returns([ [ :Macro1 ] ])
    Macro1.any_instance.stubs(:tasks).returns([
      [
        [ :success ],
        [ :never ]
      ],
      [
        [ :fail ],
        [ :timeout ],
        [ :retry ],
        [ :success ]
      ],
      [
        [ :raise, {
          :raise => {
            :nodeset => @nodeset.half,
            :status => :KO,
          }
        }],
        [ :success ]
      ],
      [ :end ]
    ])
    Microstep.any_instance.stubs(:fail).once.returns(false)
    Microstep.any_instance.stubs(:timeout).once.lasts(3).returns(true)
    Microstep.any_instance.stubs(:retry).twice.returns(false)
    Microstep.any_instance.stubs(:never).never
    Microstep.any_instance.stubs(:raise).once.returns(true)
    Microstep.any_instance.stubs(:success).times(3).returns(true)
    Microstep.any_instance.stubs(:end).twice.returns(true)

    workflow = Workflow.new(@nodeset)
    workflow.config({
      :Macro1 => {
        :config => {
          :timeout => {
            :timeout => 1,
          },
          :retry => {
            :retries => 1,
          }
        }
      }
    })
    workflow.start

    assert_same(workflow.nodes_ok,@nodeset)
  end

  def test_raisable
  end
end

