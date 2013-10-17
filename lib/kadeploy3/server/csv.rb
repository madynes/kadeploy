require 'zlib'

module Kadeploy

class CompressedCSV
  attr_reader :file, :gz, :algorithm

  def initialize(buffer_size=100000)
    @filepath = Tempfile.new('csv')
    @gz = Zlib::GzipWriter.new(@filepath)
    @file = nil
    @algorithm = 'gzip'
    @buffer = ''
    @buffer_size = buffer_size
  end

  def close()
    @gz.write(@buffer) if !@gz.closed? and !@buffer.empty?
    @buffer.clear
    @gz.close unless @gz.closed?
    @file = File.open(@filepath,'r+')
  end

  def closed?()
    !@gz or @gz.closed?
  end

  def free
    @gz.write(@buffer) if @gz and !@gz.closed? and @buffer and !@buffer.empty?
    @gz.close if @gz and !@gz.closed?
    @file.close if @file and !@file.closed?
    @filepath.unlink # Even if not call an explicit way, the finalizer of Tempfile will remove the tempfile
    @gz = nil
    @file = nil
    @filepath = nil
    @buffer = nil
    @buffer_size = nil
  end

  def <<(str)
    @buffer << str
    if @buffer.size > @buffer_size
      @gz.write(@buffer)
      @buffer.clear
    end
  end

  def size
    if @file
      @file.size
    elsif @gz
      @gz.size
    else
      0
    end
  end
end

end
