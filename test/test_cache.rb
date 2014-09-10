#!/usr/bin/env ruby
#Launch test inside the root of the project for simple cov
if ENV['SIMPLECOV']
  require 'simplecov'
  SimpleCov.start
end
require_relative '../lib/kadeploy3/server/cache'
require_relative '../lib/kadeploy3/common/error'

require 'test/unit'
require 'tempfile'
require 'tmpdir'
require 'pp'

class Oops < Exception
  def initialize()
    super("Oops")
  end
end
class Cache < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir
    @tmpfiles = []
    @files = []
    @pathbase = []
    @wid = "@wid"
    @wid1  = "@wid1"
  end

  def create(i,size_start=30,size_inc=5)
    tmpfiles= (1..i).map { |i| Tempfile.new("FILE[#{i}]") }
    pathbase = (1..i).map { |i| "http://www.toton#{i}.fr"}
    files = tmpfiles.map { |f| f.path }
    size=size_start
    files.each do |f|
      `dd if=/dev/urandom of=#{f} bs=1 count=#{size} 2>/dev/null`
      size+=size_inc
    end
    @tmpfiles+=tmpfiles
    @files+=files
    @pathbase+=pathbase
  end

  def teardown
    @tmpfiles.each { |f| f.unlink }
    FileUtils.remove_entry_secure(@dir)
  end

  def dir_empty(path)
    Dir.foreach(path) do |f|
      return false if !['.','..'].include?(f)
    end
    true
  end

  def md5(file)
    Digest::MD5.file(file).hexdigest!
  end
  def test_basic
    cache = Kadeploy::Cache.new(@dir,300,Kadeploy::CacheIndexPVHash,true,true)
    create(5)
    f1 = cache.cache(@files[0],@pathbase[0],'u1',2,'pxe',File.size(@files[0]),@wid)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',1,'http',File.size(@files[1]),@wid)
    f3 = cache.cache(@files[2],@pathbase[2],'u1',1,'pxe',File.size(@files[2]),@wid)
    f4 = cache.cache(@files[3],@pathbase[3],'u2',2,'http',File.size(@files[3]),@wid)
    f5 = cache.cache(@files[4],@pathbase[4],'u3',1,'env',File.size(@files[4]),@wid)

    assert_not_equal(f1,f2)
    assert_not_equal(f1,f3)
    assert_not_equal(f1,f4)
    assert_not_equal(f1,f5)
    assert_not_equal(f2,f3)
    assert_not_equal(f2,f4)
    assert_not_equal(f2,f5)
    assert_not_equal(f3,f4)
    assert_not_equal(f3,f5)

    assert_equal(@files[0],f1.origin_uri)
    assert_equal(@files[1],f2.origin_uri)
    assert_equal(@files[2],f3.origin_uri)
    assert_equal(@files[3],f4.origin_uri)
    assert_equal(@files[4],f5.origin_uri)

    assert_equal(f1.file,f1.file_in_cache)

    assert_raise Kadeploy::KadeployError do #Fails, if no Exception is raised
      cache.free
    end
    assert(f1.used?,"f1 must be used")
    assert(f2.used?,"f2 must be used")
    assert(f3.used?,"f3 must be used")
    assert(f4.used?,"f4 must be used")
    assert(f5.used?,"f5 must be used")
    cache.release(@wid)
    cache.free
    assert(dir_empty(@dir))
  end
  def test_limit()
    cache = Kadeploy::Cache.new(@dir,300,Kadeploy::CacheIndexPVHash,true,true)
    create(2,50,0)
    #cache(origin_uri,version,user,priority,tag,size,file_in_cache=nil,md5=nil,mtime=nil,&block)
    f1 = cache.cache(@files[0],@pathbase[0],'u1',2,'pxe',File.size(@files[0]),@wid)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',1,'http',File.size(@files[1]),@wid)
    assert_equal(f1.size,50)
    assert_equal(f2.size,50)
    assert_equal(2,cache.nb_files)
  end

  def test_last_recently_used
    create(3,22,0)
    create(1,60)

    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)

    f1 = cache.cache(@files[0],@pathbase[0],'u1',1,'pxe',File.size(@files[0]),@wid)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',1,'http',File.size(@files[1]),@wid)
    f3 = cache.cache(@files[2],@pathbase[2],'u2',1,'http',File.size(@files[2]),@wid)
    sleep(1)
    f2.file
    cache.release(@wid)
    f4 = cache.cache(@files[3],@pathbase[3],'u1',1,'http',File.size(@files[3]),@wid)
    cache.release(@wid)

    assert_not_equal(f1,f2)
    assert_not_equal(f1,f3)
    assert_not_equal(f1,f4)
    assert_not_equal(f2,f3)
    assert_not_equal(f2,f4)
    assert_not_equal(f3,f4)
    assert(f1.is_freed?,"f1 must be freed")
    assert(!f2.is_freed?,"f2 must stay")
    assert(f3.is_freed?,"f3 must be freed")
    assert(!f4.is_freed?,"f4 must stay")
    assert_equal(@files[0],f1.origin_uri)
    assert_equal(@files[1],f2.origin_uri)
    assert_equal(@files[2],f3.origin_uri)
    assert_equal(@files[3],f4.origin_uri)

    cache.free
    assert(dir_empty(@dir))
  end

  def test_prio
    create(3,22,0)
    create(1,60)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',1,'http',File.size(@files[1]),@wid)
    f3 = cache.cache(@files[2],@pathbase[2],'u2',1,'http',File.size(@files[2]),@wid)
    cache.release(@wid)
    sleep(1)
    f2.file
    f4 = cache.cache(@files[3],@pathbase[3],'u2',1,'http',File.size(@files[3]),@wid)
    cache.release(@wid)

    assert_not_equal(f1,f2)
    assert_not_equal(f1,f3)
    assert_not_equal(f1,f4)
    assert_not_equal(f2,f3)
    assert_not_equal(f2,f4)
    assert_not_equal(f3,f4)
    assert(!f1.is_freed?,"f1 must stay")
    assert(f2.is_freed?,"f2 must be freed")
    assert(f3.is_freed?,"f3 must be freed")
    assert(!f4.is_freed?,"f4 must be stay")
    assert_equal(@files[0],f1.origin_uri)
    assert_equal(@files[1],f2.origin_uri)
    assert_equal(@files[2],f3.origin_uri)
    assert_equal(@files[3],f4.origin_uri)

    cache.free
    assert(dir_empty(@dir))
  end
  def test_anonymous
    create(3,22,0)
    create(1,60)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    f3 = cache.cache(@files[2],@pathbase[2],'u2',1,'http',File.size(@files[2]),@wid)
    cache.release(@wid)
    cache.clean
    assert(!f1.is_freed?,"f1 must stay")
    assert(f2.is_freed?,"f2 must be freed")
    assert(!f3.is_freed?,"f3 must be freed")
    cache.free
    assert(dir_empty(@dir))
  end
  def test_reload_empty
    create(3,22,0)
    create(1,60)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    f3 = cache.cache(@files[2],@pathbase[2],'u2',1,'http',File.size(@files[2]),@wid)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    assert_equal(0,cache.nb_files)
    assert(dir_empty(@dir),"Dir is not empty!")
  end
  def test_reload
    create(3,22,0)
    hashf1 = Digest::MD5.file(@files[0]).hexdigest!
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'uaaa',2,'pxe',File.size(@files[0]),@wid,
        nil,hashf1,'2007-02-25 15:20')
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    f3 = cache.cache(@files[2],@pathbase[2],'u2',1,'env',File.size(@files[2]),@wid)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,false,true)
    assert_equal(3,cache.nb_files)

    h1 = cache.files[f1.file_in_cache].to_hash
    assert_nil(h1[:lock],"no lock could be saved")
    assert_nil(h1[:refs], "no refs could be saved")
    assert_not_nil(h1[:atime_virt], "atime could be saved")
    assert_equal(@files[0],h1[:origin_uri])
    assert_equal(f1.file_in_cache,h1[:file_in_cache])
    assert_equal(@pathbase[0],h1[:version])
    assert_equal(2,h1[:priority])
    assert_equal('uaaa',h1[:user])
    assert_equal('pxe',h1[:tag] )
    assert_equal(hashf1,h1[:md5])
    assert_equal('2007-02-25 15:20',h1[:mtime])
    assert_equal(22,h1[:size])

    assert_equal(f1.to_hash,cache.files[f1.file_in_cache].to_hash)
    assert_equal(f2.to_hash,cache.files[f2.file_in_cache].to_hash)
    assert_equal(f3.to_hash,cache.files[f3.file_in_cache].to_hash)
    cache.free
    assert(dir_empty(@dir),"Dir is not empty!")
  end
  def test_reload_with_fail
    create(3,22,0)
    hashf1 = Digest::MD5.file(@files[0]).hexdigest!
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'uaaa',2,'pxe',File.size(@files[0]),@wid,
        nil,hashf1,'2007-02-25 15:20')
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    f3 = cache.cache(@files[2],@pathbase[2],'u2',1,'env',File.size(@files[2]),@wid)
    File.open(f2.meta,'w'){}
    cache2= Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,false,true)
    assert_equal(2,cache2.nb_files)

    h1 = cache2.files[f1.file_in_cache].to_hash
    assert_nil(h1[:lock], "no lock could be saved")
    assert_nil(h1[:refs], "no refs could be saved")
    assert_not_nil(h1[:atime_virt], "atime could be saved")
    assert_equal(@files[0],h1[:origin_uri])
    assert_equal(f1.file_in_cache,h1[:file_in_cache])
    assert_equal(@pathbase[0],h1[:version])
    assert_equal(2,h1[:priority])
    assert_equal('uaaa',h1[:user])
    assert_equal('pxe',h1[:tag] )
    assert_equal(hashf1,h1[:md5])
    assert_equal('2007-02-25 15:20',h1[:mtime])
    assert_equal(22,h1[:size])

    assert_equal(f1.to_hash,cache2.files[f1.file_in_cache].to_hash)
    assert_equal(f3.to_hash,cache2.files[f3.file_in_cache].to_hash)
    cache.release(@wid)
    cache.free
  end
  def test_reload_with_fail2
    skip("This test does not work with root user") if ENV["USER"] == "root"
    create(3,22,0)
    hashf1 = Digest::MD5.file(@files[0]).hexdigest!
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'uaaa',2,'pxe',File.size(@files[0]),@wid,
        nil,hashf1,'2007-02-25 15:20')
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    f3 = cache.cache(@files[2],@pathbase[2],'u2',1,'env',File.size(@files[2]),@wid)
    system("chmod 000 #{f2.meta}")
    assert(!File.readable?(f2.meta),"#{f2.meta} must be unreadable")
    cache2= Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,false,true)
    assert_equal(2,cache2.nb_files)

    h1 = cache2.files[f1.file_in_cache].to_hash
    assert_nil(h1[:lock], "no lock could be saved")
    assert_nil(h1[:refs], "no refs could be saved")
    assert_not_nil(h1[:atime_virt], "atime could be saved")
    assert_equal(@files[0],h1[:origin_uri])
    assert_equal(f1.file_in_cache,h1[:file_in_cache])
    assert_equal(@pathbase[0],h1[:version])
    assert_equal(2,h1[:priority])
    assert_equal('uaaa',h1[:user])
    assert_equal('pxe',h1[:tag] )
    assert_equal(hashf1,h1[:md5])
    assert_equal('2007-02-25 15:20',h1[:mtime])
    assert_equal(22,h1[:size])

    assert_equal(f1.to_hash,cache2.files[f1.file_in_cache].to_hash)
    assert_equal(f3.to_hash,cache2.files[f3.file_in_cache].to_hash)
    cache.release(@wid)
    system("chmod 666 #{f2.meta}")
    cache.free
  end
  def test_new_mtime
    create(3,50,0)
    f0md5= md5(@files[0])
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid1,nil,nil,Time.now.to_s)
    cache.release(@wid1)
    assert_equal(0,f1.refs.size)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    FileUtils.cp(@files[2], @files[0])
    sleep(1)
    f3 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid,nil,nil,Time.now.to_s)
    #must be fetched
    assert_equal(f1,f3)
    assert_equal(md5(f1.file_in_cache), md5(@files[2]))
    assert_not_equal(md5(f1.file_in_cache), f0md5)
  end
  def test_old_mtime
    create(3,50,0)
    f0md5= md5(@files[0])
    assert_not_equal(@files[0],@files[2],"files must be different")
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    t = Time.now.to_s
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid,nil,nil,t)
    f1.release(@wid)
    assert_equal(0,f1.refs.size)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    FileUtils.cp(@files[2], @files[0])
    f3 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid,nil,nil,t)
    #The file must not be fetched
    assert_equal(f1,f3)
    assert_equal(md5(f1.file_in_cache), f0md5)
    assert_not_equal(md5(f1.file_in_cache), md5(@files[2]))
  end
  def test_new_md5
    create(3,50,0)
    f0md5= md5(@files[0])
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid,nil,md5(@files[0]))
    f1.release(@wid)
    assert_equal(0,f1.refs.size)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    FileUtils.cp(@files[2], @files[0])
    f3 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid,nil,md5(@files[0]))
    #must be fetched
    assert_equal(f1,f3)
    assert_equal(md5(f1.file_in_cache), md5(@files[2]))
    assert_not_equal(md5(f1.file_in_cache), f0md5)
  end
  def test_old_md5
    create(3,50,0)
    f0md5= md5(@files[0])
    assert_not_equal(@files[0],@files[2],"files must be different")
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    t = md5(@files[0])
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid,nil,t)
    f1.release(@wid)
    assert_equal(0,f1.refs.size)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    FileUtils.cp(@files[2], @files[0])
    f3 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid,nil,t)
    #The file must not be fetched
    assert_equal(f1,f3)
    assert_equal(md5(f1.file_in_cache), f0md5)
    assert_not_equal(md5(f1.file_in_cache), md5(@files[2]))
  end
  def test_bad_md5()
    create(3,50,0)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid,nil,md5(@files[0]))
    assert_raise Kadeploy::KadeployError do #Fails, if no Exception is raised
      f2 = cache.cache(@files[1],@pathbase[1],'u2',2,'pxe',File.size(@files[1]),@wid,nil,"zejfziojfoazeifjozeijfazoiefo")
    end
    f3 = cache.cache(@files[2],@pathbase[2],'u2',2,'pxe',File.size(@files[2]),@wid,nil,md5(@files[2]))
    assert_equal(2,cache.nb_files)
  end
  def test_bad_size()
    create(3,50,0)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    assert_raise Kadeploy::KadeployError do #Fails, if no Exception is raised
      f2 = cache.cache(@files[1],@pathbase[1],'u2',2,'pxe',54544,@wid)
    end
    f3 = cache.cache(@files[2],@pathbase[2],'u2',2,'pxe',File.size(@files[2]),@wid)
    assert_equal(2,cache.nb_files)
  end
  def test_cache_is_full()
    create(3,50,0)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u1',2,nil,File.size(@files[0]),@wid)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',1,nil,File.size(@files[1]),@wid)
    assert_raise Kadeploy::KadeployError do #Fails, if no Exception is raised
      f3 = cache.cache(@files[2],@pathbase[2],'u1',1,nil,File.size(@files[2]),@wid)
    end
    assert_equal(2,cache.nb_files)
  end

  def test_fetch()
    create(2,50,0)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',2,'pxe',File.size(@files[1]),@wid) do |origin,fic,size,md5|
      FileUtils.cp(origin,fic)
    end
    assert_equal(2,cache.nb_files)
  end
  def test_raise_fetch()
    create(3,50,0)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    assert_raise Oops do #Fails, if no Exception is raised
      f2 = cache.cache(@files[1],@pathbase[1],'u2',2,'pxe',File.size(@files[1]),@wid) do
        raise Oops.new()
      end
    end
    f3 = cache.cache(@files[2],@pathbase[2],'u2',2,'pxe',File.size(@files[2]),@wid)
    assert_equal(2,cache.nb_files)
  end
  def test_Cache_index()
    create(1,50,0)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPath,true,true)
    assert_raise Kadeploy::KadeployError do #Fails, if no Exception is raised
      f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    end
    assert_equal(0,cache.nb_files)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid,"/tmp/toto.txt")
    assert_equal(1,cache.nb_files)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPath,false,true)
    assert_equal(1,cache.nb_files)
    assert_equal(f1.to_hash,cache.files[f1.file_in_cache].to_hash)
    cache.free()
    assert(!File.exists?(f1.file_in_cache))
  end
  def test_Cache_until_fetch()
    create(3,50,0)
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = nil
    th = Thread.new do
      f1 = cache.cache(@files[0],@pathbase[0],'u0',0,'pxe',File.size(@files[0]),@wid) do |origin,fic,size,md5|
        sleep(1)
        FileUtils.cp(origin,fic)
      end
    end
    sleep(0.2)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,nil,File.size(@files[1]),@wid1)
    cache.release(@wid1)
    f3 = cache.cache(@files[2],@pathbase[2],'u3',1,nil,File.size(@files[2]),@wid)
    th.join
    assert_equal(2,cache.nb_files)
    cache.release(@wid)
    cache.free()
  end
  def test_new_size
    create(3,50,5)
    cache = Kadeploy::Cache.new(@dir,120,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    f1.release(@wid)
    assert_equal(0,f1.refs.size)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    f2.release(@wid)
    FileUtils.cp(@files[2], @files[0])
    f3 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[2]),@wid)
    #must be fetched
    assert_equal(f1,f3)
    assert_equal(md5(f1.file_in_cache), md5(@files[2]))
  end
  def test_new_size_alone
    create(3,50,5)
    cache = Kadeploy::Cache.new(@dir,105,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    f1.release(@wid)
    assert_equal(0,f1.refs.size)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    f2.release(@wid)
    FileUtils.cp(@files[2], @files[0])
    f3 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    #must be fetched
    assert_equal(f1.file_in_cache,f3.file_in_cache)
    assert_equal(md5(f1.file_in_cache), md5(@files[2]))
    assert_equal(1,cache.nb_files())
  end
  def test_new_size_used
    create(3,50,10)
    cache = Kadeploy::Cache.new(@dir,200,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    assert(f1.used?)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    assert(f2.used?)
    FileUtils.cp(@files[2], @files[0])
    assert_raise Kadeploy::KadeployError do #Fails, if no Exception is raised
      f3 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[2]),@wid1)
    end
    assert_not_equal(md5(f1.file_in_cache), md5(@files[2]))
  end

  def test_old_size_used
    create(3,50,0)
    assert_not_equal(@files[0],@files[2],"files must be different")
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    FileUtils.cp(@files[2], @files[0])
    assert(f1.used?)
    f3 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    #The file must not be fetched
    assert_equal(f1,f3)
    assert_not_equal(md5(f1.file_in_cache), md5(@files[2]))
  end
  def test_old_size
    create(3,50,0)
    size = File.size(@files[0])
    assert_not_equal(@files[0],@files[2],"files must be different")
    cache = Kadeploy::Cache.new(@dir,100,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    f1.release(@wid)
    assert_equal(0,f1.refs.size)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    FileUtils.cp(@files[2], @files[0])
    f3 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',size,@wid)
    #The file must not be fetched
    assert_equal(f1,f3)
    assert_not_equal(md5(f1.file_in_cache), md5(@files[2]))
  end
  def test_nil_priority
    cache = Kadeploy::Cache.new(@dir,300,Kadeploy::CacheIndexPVHash,true,true)
    create(1)
    assert_raise RuntimeError do #Fails, if no Exception is raised
      f1 = cache.cache(@files[0],@pathbase[0],'u1',nil,'pxe',File.size(@files[0]),@wid)
    end
    cache.free
  end
  def test_token
    create(3,50,0)
    cache = Kadeploy::Cache.new(@dir,200,Kadeploy::CacheIndexPVHash,true,true)
    f1 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid)
    f2 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid1)
    assert_equal(1,f1.refs.size)
    assert_equal(1,f2.refs.size)
    f3 = cache.cache(@files[0],@pathbase[0],'u2',2,'pxe',File.size(@files[0]),@wid1)
    f4 = cache.cache(@files[1],@pathbase[1],'u2',0,'http',File.size(@files[1]),@wid)
    assert_equal(f1,f3)
    assert_equal(f2,f4)
    assert_equal(2,f1.refs.size)
    assert_equal(2,f2.refs.size)
    cache.release(@wid)
    cache.release(@wid)
    assert_equal(1,f1.refs.size)
    assert_equal(1,f2.refs.size)
    cache.release(@wid1)
    cache.release(@wid1)
    assert_equal(0,f1.refs.size)
    assert_equal(0,f2.refs.size)
  end
end
