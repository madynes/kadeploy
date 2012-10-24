require 'ka_test_case'
require 'test/unit'
require 'tempfile'

class TestKareboot  < Test::Unit::TestCase
  include KaTestCase

  def setup
    load_config()
    @binary = @binaries[:kareboot]
    @kind = 'simple_reboot'
  end

  def run_kareboot(*options)
    options += ['-r',@kind] if @kind

    run_ka_nodelist(@binary,*options)
  end

  def test_simple
    run_kareboot()
  end

  def test_set_pxe
  end

  def test_set_pxe_singularity
  end

  def test_deploy_env
  end

  def test_env_recorded
  end

  def test_check_prod_env
  end
end

