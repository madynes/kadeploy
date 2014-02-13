$:.unshift File.dirname(__FILE__)
require 'ka_test_case'
require 'test/unit'
require 'tempfile'
require 'tmpdir'
require 'rubygems'
require 'kadeploy3/common/http'
require 'base64'

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
      Kadeploy::HTTP::Client.gen_request(:DELETE,"/power/#{@wid}",
        nil,nil,nil,{"#{KADEPLOY_AUTH_HEADER}User"=>USER})
    ) if @wid
  end

  def get(path,headers=nil,http_auth=nil,server=KADEPLOY_SERVER,port=KADEPLOY_PORT,secure=KADEPLOY_SECURE)
    headers = {} if headers.nil?
    headers = {"#{KADEPLOY_AUTH_HEADER}User"=>USER}.merge!(headers) if http_auth.nil?
    begin
      req = Kadeploy::HTTP::Client.gen_request(:GET,path,nil,nil,nil,headers)
      req.basic_auth(http_auth[:user],http_auth[:password]) if http_auth
      Kadeploy::HTTP::Client.request(server,port,secure,req)
    rescue Exception => e
      assert(false,e.message)
    end
  end

  def test_acl()
    ret = get("/power",nil,nil,'localhost')
    assert(!ret.select{|v| v['wid'] == @wid}.empty?,ret.to_yaml)
  end

  def test_ident()
    ret = get("/power")
    assert(!ret.select{|v| v['wid'] == @wid}.empty?,ret.to_yaml)
  end

  def test_ident_no_user()
    ret = get("/power",nil,false)
    assert(!ret.select{|v| v['wid'] == @wid}.empty?,ret.to_yaml)
  end

  def test_cert()
    cert = Base64.strict_encode64(File.read(KADEPLOY_CERT_FILE))
    ret = get("/power",{"#{KADEPLOY_AUTH_HEADER}Certificate"=>cert})
    elem = ret.select{|v| v['wid'] == @wid}
    assert(!elem.empty?,ret.to_yaml)
    elem = elem[0]
    assert(elem.keys.include?('time'),"Get state did not return the admin view\n"+ret.to_yaml)
  end

  def test_cert_no_user()
    cert = Base64.strict_encode64(File.read(KADEPLOY_CERT_FILE))
    ret = get("/power",{"#{KADEPLOY_AUTH_HEADER}Certificate"=>cert},false)
    elem = ret.select{|v| v['wid'] == @wid}
    assert(!elem.empty?,ret.to_yaml)
    elem = elem[0]
    assert(elem.keys.include?('time'),"Get state did not return the admin view\n"+ret.to_yaml)
  end

  def test_http_basic()
    ret = get("/power",nil,{:user=>USER,:password=>KADEPLOY_SECRET_KEY})
    elem = ret.select{|v| v['wid'] == @wid}
    assert(!elem.empty?,ret.to_yaml)
    elem = elem[0]
    assert(elem.keys.include?('time'),"Get state did not return the admin view\n"+ret.to_yaml)
  end
end
