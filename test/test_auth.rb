$:.unshift File.dirname(__FILE__)
require 'ka_test_case'
require 'test/unit'
require 'tempfile'
require 'tmpdir'
require 'rubygems'
require 'kadeploy3/http'

class TestAuth < Test::Unit::TestCase
  include KaTestCase
  KADEPLOY_CERT_FILE=ENV['KADEPLOY3_CERT_FILE']||'/etc/kadeploy3/admin.pem'
  KADEPLOY_SECRET_KEY=ENV['KADEPLOY3_SECRET_KEY']||'KADEPLOY'

  def setup()
    load_config()
    ret = run_ka(@binaries[:kapower],'--on','-m',@nodes[0],'--no-wait')
    @wid = ret.split("\n").last.split(' ')[0]
  end

  def teardown
    Kadeploy::HTTP::Client.request(
      KADEPLOY_SERVER,KADEPLOY_PORT,KADEPLOY_SECURE,
      Kadeploy::HTTP::Client.gen_request(:DELETE,"/power/#{@wid}?user=#{USER}")
    ) if @wid
  end

  def get(path,data=nil)
    begin
      Kadeploy::HTTP::Client.request(
        KADEPLOY_SERVER,KADEPLOY_PORT,KADEPLOY_SECURE,
        Kadeploy::HTTP::Client.gen_request(:GET,path,data,:json,:json)
      )
    rescue Exception => e
      assert(false,e.message)
    end
  end

  def test_ident()
    ret = get("/power?user=#{USER}")
    assert(!ret.select{|v| v['id'] == @wid}.empty?,ret.to_yaml)
  end

  def test_cert()
    data = {
      :user => 'root',
      :cert => File.read(KADEPLOY_CERT_FILE),
    }
    ret = get("/power",data)
    elem = ret.select{|v| v['id'] == @wid}
    assert(!elem.empty?,ret.to_yaml)
    elem = elem[0]
    assert(elem.keys.include?('time'),"Get state did not return the admin view\n"+ret.to_yaml)
  end

  def test_secret_key()
    data = {
      :user => 'root',
      :secret_key => KADEPLOY_SECRET_KEY,
    }
    ret = get("/power",data)
    elem = ret.select{|v| v['id'] == @wid}
    assert(!elem.empty?,ret.to_yaml)
    elem = elem[0]
    assert(elem.keys.include?('time'),"Get state did not return the admin view\n"+ret.to_yaml)
  end
end
