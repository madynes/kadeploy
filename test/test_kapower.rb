$:.unshift File.dirname(__FILE__)
require 'ka_test_case'
require 'test/unit'
require 'tempfile'

class TestKapower < Test::Unit::TestCase
  include KaTestCase
  R_WID = /^P-[a-z0-9-]+$/

  def setup
    load_config()
    @binary = @binaries[:kapower]
    @nodefiles = true
  end

  def run_kapower(*options)
    options += ['-f',@nodefile]
    options << '--force'
    if @nodefiles
      run_ka_nodelist(@binary,*options)
    else
      run_ka(@binary,*options)
    end
  end

  def test_on
    run_kapower('--on')
  end

  def test_off
    run_kapower('--off')
  end

  def test_status
    run_kapower('--status')
  end

  def test_no_wait
    @nodefiles = false
    ret = run_kapower('--off','--no-wait')
    assert(ret.split(' ')[0] =~ R_WID,ret)
  end
end

