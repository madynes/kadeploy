$:.unshift File.join(File.dirname(__FILE__), '..', 'src','lib')
require 'cache'
require 'md5'
require 'test/unit'
require 'tempfile'
require 'tmpdir'
require 'pp'

class TestCache < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir
    @tmpfiles = []
    10.times { |i| @tmpfiles << Tempfile.new("FILE[#{i}]") }
    @files = []
    @tmpfiles.each { |f| @files << f.path }
  end

  def teardown
    @tmpfiles.each { |f| f.unlink }
    FileUtils.remove_entry_secure(@dir)
  end

  def test_default
    dir = Dir.mktmpdir
    `dd if=/dev/urandom of=#{@files[0]} bs=1 count=30 2>/dev/null`
    `dd if=/dev/urandom of=#{@files[1]} bs=1 count=45 2>/dev/null`
    `dd if=/dev/urandom of=#{@files[2]} bs=1 count=20 2>/dev/null`
    `dd if=/dev/urandom of=#{@files[3]} bs=1 count=50 2>/dev/null`
    `cp #{@files[3]} #{@files[4]}`

    hashs = []
    @files[0..4].each { |f| hashs << lambda { MD5::get_md5_sum(f) } }

    cache = Cache.new(@dir,100,CacheIndexPHash)

    f1 = cache.cache(@files[0],'http://testbed.lan/FILE0','u1',2,'pxe',hashs[0],Time.now)
    f1dup = f1.dup
    f2 = cache.cache(@files[1],'/home/testuser/FILE1','u2',1,'http',hashs[1],Time.now)
    f3 = cache.cache(@files[2],'http://testbed.lan/FILE2','u1',1,'pxe',hashs[2],Time.now)
    f4 = cache.cache(@files[3],'http://testbed.lan/FILE0','u2',2,'http',hashs[3],Time.now)
    f4dup = f4.dup
    f5 = cache.cache(@files[4],'http://testbed.lan/FILE0','u3',1,'env',hashs[4],Time.now)
    f5dup = f5.dup

    assert_not_equal(f1,f2)
    assert_not_equal(f1,f3)
    assert_not_equal(f1,f4)
    assert_not_equal(f1dup.filename,f4dup.filename)
    assert_not_equal(f1,f5)
    assert_not_equal(f1dup.filename,f5dup.filename)
    assert_not_equal(f2,f3)
    assert_not_equal(f2,f4)
    assert_not_equal(f2,f5)
    assert_not_equal(f3,f4)
    assert_not_equal(f3,f5)
    assert_equal(f4,f5)
    assert_not_equal(f4dup.filename,f5dup.filename)

    assert(cache.hit?(:path => f1.path))
    assert(cache.hit?(:path => f2.path))
    assert(!cache.hit?(:path => f3.path))

pp cache.files
    cache2 = Cache.new(@dir,100,CacheIndexPHash)
    assert_equal(cache.files.keys,cache2.files.keys)

    cache.free
    cache2.free
  end

  def test_lru
    dir = Dir.mktmpdir
    `dd if=/dev/urandom of=#{@files[0]} bs=1 count=15 2>/dev/null`
    `dd if=/dev/urandom of=#{@files[1]} bs=1 count=15 2>/dev/null`
    `dd if=/dev/urandom of=#{@files[2]} bs=1 count=15 2>/dev/null`
    `dd if=/dev/urandom of=#{@files[3]} bs=1 count=60 2>/dev/null`

    hashs = []
    @files[0..3].each { |f| hashs << lambda { MD5::get_md5_sum(f) } }

    cache = Cache.new(@dir,100,CacheIndexPHash)

    pathbase = 'http://testbed.lan/FILE'

    f1 = cache.cache(@files[0],pathbase+'0','u1',1,'pxe',hashs[0],Time.now)
    sleep(1)
    f2 = cache.cache(@files[1],pathbase+'1','u2',1,'http',hashs[1],Time.now)
    sleep(1)
    f3 = cache.cache(@files[2],pathbase+'2','u2',1,'http',hashs[1],Time.now)
    sleep(1)
    f1.update_atime
    f4 = cache.cache(@files[3],pathbase+'3','u1',1,'http',hashs[1],Time.now)

    assert_not_equal(f1,f2)
    assert_not_equal(f1,f3)
    assert_not_equal(f1,f4)
    assert_not_equal(f2,f3)
    assert_not_equal(f2,f4)
    assert_not_equal(f3,f4)
    assert(cache.hit?(:path => pathbase+'0'))
    assert(!cache.hit?(:path => pathbase+'1'))
    assert(cache.hit?(:path => pathbase+'2'))
    assert(cache.hit?(:path => pathbase+'3'))

pp cache.files

    cache.free
  end

  def test_prio
    dir = Dir.mktmpdir
    `dd if=/dev/urandom of=#{@files[0]} bs=1 count=15 2>/dev/null`
    `dd if=/dev/urandom of=#{@files[1]} bs=1 count=15 2>/dev/null`
    `dd if=/dev/urandom of=#{@files[2]} bs=1 count=15 2>/dev/null`
    `dd if=/dev/urandom of=#{@files[3]} bs=1 count=60 2>/dev/null`

    hashs = []
    @files[0..3].each { |f| hashs << lambda { MD5::get_md5_sum(f) } }

    cache = Cache.new(@dir,100,CacheIndexPHash)

    pathbase = 'http://testbed.lan/FILE'

    f1 = cache.cache(@files[0],pathbase+'0','u1',2,'pxe',hashs[0],Time.now)
    f2 = cache.cache(@files[1],pathbase+'1','u2',1,'http',hashs[1],Time.now)
    f3 = cache.cache(@files[2],pathbase+'2','u2',1,'http',hashs[1],Time.now)
    sleep(1)
    f2.update_atime
    f4 = cache.cache(@files[3],pathbase+'3','u1',1,'http',hashs[1],Time.now)

    assert_not_equal(f1,f2)
    assert_not_equal(f1,f3)
    assert_not_equal(f1,f4)
    assert_not_equal(f2,f3)
    assert_not_equal(f2,f4)
    assert_not_equal(f3,f4)
    assert(cache.hit?(:path => pathbase+'0'))
    assert(cache.hit?(:path => pathbase+'1'))
    assert(!cache.hit?(:path => pathbase+'2'))
    assert(cache.hit?(:path => pathbase+'3'))

pp cache.files

    cache.free
  end
end
