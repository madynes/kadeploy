require 'ka_test_case'
require 'test/unit'
require 'tempfile'

class TestKapower < Test::Unit::TestCase
  include KaTestCase

  def setup
    load_config()
    @binary = @binaries[:kapower]
  end

  def run_kapower(*options)
    options += ['-f',@nodefile]
    run_ka_check(@binary,*options)
  end

  def test_async
    @async = true
    name = 'kapower'
    binary = Tempfile.new("#{name}-async_")
    binary.write(`cat $(which #{@binary}) | sed s/#{name}.rb/#{name}_async.rb/g`)
    binary.close
    `chmod +x #{binary.path}`

    begin
      @binary = binary.path
      run_kapower('--off')
    ensure
      binary.unlink
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
    run_kapower('--off','--no-wait')
  end
end

