$:.unshift File.dirname(__FILE__)
require 'ka_test_case'
require 'test/unit'
require 'tempfile'
require 'tmpdir'
require 'rubygems'
require 'date'

class TestStat < Test::Unit::TestCase
  include KaTestCase
  R_WID = /^P-[a-z0-9-]+$/

  def setup
    load_config()
    @binary = @binaries[:kastat]
    run_ka(@binaries[:kapower],'--on','-m',@nodes[0])
  end

  def run_kastat(*options)
    options += ['-m',@nodes[0]]
    options += ['-l','1']
    run_ka(@binary,*options)
  end

  def test_simple
    run_kastat()
  end

  def test_operation
    ret = run_kastat('-o','power','-F','wid')
    assert(ret.strip =~ R_WID,ret)
  end

  def test_fields
    ret = run_kastat('-F','wid')
    assert(ret.strip =~ R_WID,ret)
    ret = run_kastat('-F','user')
    assert_equal(ret.strip,USER,ret)
    ret = run_kastat('-F','hostname')
    assert_equal(ret.strip,@nodes[0],ret)
    ret = run_kastat('-F','step1')
    assert_equal(ret.strip,'On',ret)
  end

  def test_date
    ret = run_kastat('-o','power','-F','wid','-x',Date.today.to_s,'-y',Time.now.to_s)
    assert(ret.strip =~ R_WID,ret)
  end

  def test_failure_rate
    ret = run_kastat('-o','power','-b','0')
    assert(ret.strip =~ /^#{@nodes[0]}/,ret)
  end
end
