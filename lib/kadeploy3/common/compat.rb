# Ugly hacks for ruby 1.8 backwards compatibility
if RUBY_VERSION < '1.9'
  class String
    def encoding
      'US-ASCII'
    end
  end

  class Array
    def select!(*args,&block)
      replace(select(*args,&block))
    end

    def sort_by!(*args,&block)
      replace(sort_by(*args,&block))
    end
  end

  class Symbol
    def empty?
      to_s.empty?
    end
  end

  class Float
    alias_method :__round__, :round
    def round(*args)
      __round__()
    end
  end

  class File
    def self.absolute_path(path)
      Pathname.new(path).realpath
    end

    def size()
      File.size(self.path())
    end
  end

  module Base64
    def self.urlsafe_encode64(bin)
      strict_encode64(bin).tr("+/", "-_")
    end

    def self.urlsafe_decode64(str)
      str.tr("-_", "+/").unpack("m0").first
    end

    def self.strict_encode64(bin)
      encode64(bin).gsub("\n",'')
    end

    def self.strict_decode64(str)
      decode64(str)
    end
  end

  module URI
    def self.encode_www_form_component(str,*args)
      encode(str.to_s)
    end

    def self.encode_www_form(enum)
      enum.map do |k,v|
        if v.nil?
          encode_www_form_component(k)
        elsif v.respond_to?(:to_ary)
          v.to_ary.map do |w|
            str = encode_www_form_component(k)
            unless w.nil?
              str << '='
              str << encode_www_form_component(w)
            end
          end.join('&')
        else
          str = encode_www_form_component(k)
          str << '='
          str << encode_www_form_component(v)
        end
      end.join('&')
    end

    def self.decode_www_form_component(str,*args)
      decode(str)
    end

    def self.decode_www_form(str)
      return [] if str.empty?
      unless /\A#{WFKV_}=#{WFKV_}(?:[;&]#{WFKV_}=#{WFKV_})*\z/ =~ str
        raise ArgumentError, "invalid data of application/x-www-form-urlencoded (#{str})"
      end
      ary = []
      $&.scan(/([^=;&]+)=([^;&]*)/) do
        ary << [decode($1), decode($2)]
      end
      ary
    end
  end

  module SecureRandom
    def self.uuid
      ary = self.random_bytes(16).unpack("NnnnnN")
      ary[2] = (ary[2] & 0x0fff) | 0x4000
      ary[3] = (ary[3] & 0x3fff) | 0x8000
      "%08x-%04x-%04x-%04x-%04x%08x" % ary
    end
  end

  def STDIN.raw()
    begin
      system('stty raw -echo')
      yield(STDIN)
    ensure
      system('stty -raw echo')
    end
  end

  def STDIN.cooked!()
    system('stty cooked')
  end

  def STDIN.winsize()
    ret = `stty size`.strip
    if ret.empty?
      []
    else
      ret.split(/\s+/).collect{|v| v.to_i rescue nil}.compact
    end
  end

  module Psych
    class SyntaxError < Exception
    end
  end
end
