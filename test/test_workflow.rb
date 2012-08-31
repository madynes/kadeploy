require 'rubygems'
require 'test/unit'
require 'mocha'
require 'mocha_patch'
require 'automata_test_case'

class TestWorkflow < Test::Unit::TestCase
  include AutomataTestCase

  def test_scenario
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
    Micro1.any_instance.stubs(:success).times(3).lasts(3,1).returns(true)
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
