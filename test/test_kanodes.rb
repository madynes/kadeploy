$:.unshift File.dirname(__FILE__)
require 'ka_test_case'
require 'test/unit'
require 'tempfile'
require 'tmpdir'
require 'yaml'
require 'rubygems'
require 'kadeploy3/common/http'

class TestNodes < Test::Unit::TestCase
  include KaTestCase

  def setup
    load_config()
    @binary = @binaries[:kanodes]
  end

  def run_kanodes(*options)
    run_ka(@binary,*options)
  end

  def test_state
    run_ka(@binaries[:kapower],'--on','-m',@nodes[0])
    ret = run_kanodes('-s','-m',@nodes[0])
    begin
      desc = YAML.load(ret)
      assert(desc.keys[0] == @nodes[0],ret)
      assert(desc[desc.keys[0]]['state'] == 'powered',ret)
      assert(desc[desc.keys[0]]['user'] == USER,ret)
    rescue ArgumentError => ae
      assert(false,ae.message)
    end
  end

  def test_status
    ret = run_ka(@binaries[:kapower],'--on','-m',@nodes[0],'--no-wait')
    wid = ret.split("\n").last.split(' ')[0]
    ret = run_kanodes('-p')
    begin
      desc = YAML.load(ret)
      assert(!desc.select{|v| v[:wid] == wid}.empty?,ret)
    rescue ArgumentError => ae
      assert(false,ae.message)
    ensure
      Kadeploy::HTTP::Client.request(
        KADEPLOY_SERVER,KADEPLOY_PORT,KADEPLOY_SECURE,
        Kadeploy::HTTP::Client.gen_request(:DELETE,"/power/#{wid}",
          nil,nil,nil,{"#{KADEPLOY_AUTH_HEADER}User"=>USER})
      )
    end
  end
end
