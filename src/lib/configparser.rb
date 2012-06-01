require 'pathname'
require 'fileutils'

module ConfigInformation
  class ParserError < StandardError
  end

  class ConfigParser
    attr_reader :basehash
    PATH_SEPARATOR = '/'

    def initialize(confighash)
      @basehash = confighash
      # The current path
      @path = []
      # The current value
      @val = confighash
    end

    def push(fieldname, val=nil)
      @path.push(fieldname)
      @val = (val.nil? ? curval() : val)
    end

    def pop(val=nil)
      @path.pop
      @val = (val.nil? ? curval() : val)
    end

    def depth
      @path.size
    end

    def path(val=nil)
      ConfigParser.pathstr(@path + [val])
    end

    def curval
      ret = @basehash
      @path.compact.each do |field|
        begin
          field = Integer(field)
        rescue ArgumentError
        end

        if ret[field]
          ret = ret[field]
        else
          ret = nil
          break
        end
      end
      ret
    end

    def self.errmsg(field,message)
      "#{message} [field: #{field}]"
    end

    def self.pathstr(array)
      array.compact.join(PATH_SEPARATOR)
    end

    def check_field(fieldname,mandatory,type)
      begin
        if @val.is_a?(Hash)
          if !@val[fieldname].nil?
            if type.is_a?(Class)
              typeok = @val[fieldname].is_a?(type)
            elsif type.is_a?(Array)
              type.each do |t|
                typeok = @val[fieldname].is_a?(t)
                break if typeok
              end
            else
              raise 'Internal Error'
            end

            if typeok
              yield(@val[fieldname])
            else
              $,=','
              typename = type.to_s
              $,=nil
              raise ParserError.new(
                "The field should have the type #{typename}"
              )
            end
          elsif mandatory
            raise ParserError.new("The field is mandatory")
          else
            yield(nil)
          end
        elsif mandatory
          if @val.nil?
            raise ParserError.new("The field is mandatory")
          else
            raise ParserError.new("The field has to be a Hash")
          end
        else
          yield(nil)
        end
      rescue ParserError => pe
        raise ArgumentError.new(
          ConfigParser.errmsg(path(fieldname),pe.message)
        )
      end
    end

    def check_array(val, array, fieldname)
      unless array.include?(val)
        raise ParserError.new(
          "Invalid value '#{val}', allowed value"\
          "#{(array.size == 1 ? " is" : "s are")}: "\
          "#{(array.size == 1 ? '' : "'#{array[0..-2].join("', '")}' or ")}"\
          "'#{array[-1]}'"
        )
      end
    end

    def check_hash(val, hash, fieldname)
      self.send("customcheck_#{hash[:type].downcase}".to_sym,val,fieldname,hash)
    end

    def check_range(val, range, fieldname)
      check_array(val, range.entries, fieldname)
    end

    def check_regexp(val, regexp, fieldname)
      unless val =~ regexp
        raise ParserError.new(
          "Invalid value '#{val}', the value must have the form (ruby-regexp): "\
          "#{regexp.source}"
        )
      end
    end

    # A file, checking if exists (creating it otherwise) and writable
    def check_file(val, file, fieldname)
      if File.exists?(val)
        unless File.file?(val)
          raise ParserError.new("The file '#{val}' is not a regular file")
        end
      else
        raise ParserError.new("The file '#{val}' does not exists")
      end
    end

    # A directory, checking if exists (creating it otherwise) and writable
    def check_dir(val, dir, fieldname)
      if File.exist?(val)
        unless File.directory?(val)
          raise ParserError.new("'#{val}' is not a regular directory")
        end
      else
        raise ParserError.new("The directory '#{val}' does not exists")
      end
    end

    # A pathname, checking if exists (creating it otherwise) and writable
    def check_pathname(val, pathname, fieldname)
      begin
        Pathname.new(val)
      rescue
        raise ParserError.new("Invalid pathname '#{val}'")
      end
    end

    def check_string(val, str, fieldname)
      unless val == str
        raise ParserError.new(
          "Invalid value '#{val}', allowed values are: '#{str}'"
        )
      end
    end

    def customcheck_code(val, fieldname, args)
      begin
        eval("#{args[:prefix]}#{args[:code]}#{args[:suffix]}")
      rescue
        raise ParserError.new("Invalid expression '#{args[:code]}'")
      end
    end

    def customcheck_file(val, fieldname, args)
      return if args[:disable]
      val = File.join(args[:prefix],val) if args[:prefix]
      val = File.join(val,args[:suffix]) if args[:suffix]
      if File.exists?(val)
        if File.file?(val)
          if args[:writable]
            unless File.stat(val).writable?
              raise ParserError.new("The file '#{val}' is not writable")
            end
          end

          if args[:readable]
            unless File.stat(val).readable?
              raise ParserError.new("The file '#{val}' is not readable")
            end
          end
        else
          raise ParserError.new("The file '#{val}' is not a regular file")
        end
      else
        if args[:create]
          begin
            puts "The file '#{val}' does not exists, let's create it"
            tmp = FileUtils.touch(val)
            raise if tmp.is_a?(FalseClass)
          rescue
            raise ParserError.new("Cannot create the file '#{val}'")
          end
        else
          raise ParserError.new("The file '#{val}' does not exists")
        end
      end
    end

    def customcheck_dir(val, fieldname, args)
      return if args[:disable]
      val = File.join(args[:prefix],val) if args[:prefix]
      val = File.join(val,args[:suffix]) if args[:suffix]
      if File.exist?(val)
        if File.directory?(val)
          if args[:writable]
            unless File.stat(val).writable?
              raise ParserError.new("The directory '#{val}' is not writable")
            end
          end

          if args[:readable]
            unless File.stat(val).readable?
              raise ParserError.new("The directory '#{val}' is not readable")
            end
          end
        else
          raise ParserError.new("'#{val}' is not a regular directory")
        end
      else
        if args[:create]
          begin
            puts "The directory '#{val}' does not exists, let's create it"
            tmp = FileUtils.mkdir_p(val, :mode => (args[:mode] || 0700))
            raise if tmp.is_a?(FalseClass)
          rescue
            raise ParserError.new("Cannot create the directory '#{val}'")
          end
        else
          raise ParserError.new("The directory '#{val}' does not exists")
        end
      end
    end


    def parse(fieldname, mandatory=false, type=Hash)
      check_field(fieldname,mandatory,type) do |curval|
        oldval = @val
        push(fieldname, curval)

        if curval.is_a?(Array)
          curval.each_index do |i|
            push(i)
            yield({
              :val => curval,
              :empty => curval.nil?,
              :path => path,
              :iter => i,
            })
            pop()
          end
          curval.clear
        else
          yield({
            :val => curval,
            :empty => curval.nil?,
            :path => path,
            :iter => 0,
          })
        end

        oldval.delete(fieldname) if curval and curval.empty?

        pop(oldval)
      end
    end

    # if no defaultvalue defined, field is mandatory
    def value(fieldname,type,defaultvalue=nil,expected=nil)
      ret = nil
      check_field(fieldname,defaultvalue.nil?,type) do |val|
        if val.nil?
          ret = defaultvalue
        else
          ret = val
          @val.delete(fieldname)
        end
        #ret = (val.nil? ? defaultvalue : val)

        if expected
          classname = (
            expected.class == Class ? expected.name : expected.class.name
          ).split('::').last
          self.send(
            "check_#{classname.downcase}".to_sym,
            ret,
            expected,
            fieldname
          )
        end
      end
      ret
    end

    def unused(result = [],curval=nil,curpath=nil)
      curval = @basehash unless curval
      curpath = [] unless curpath

      if curval.is_a?(Hash)
        curval.each do |key,value|
          curpath << key
          if value.nil?
            result << ConfigParser.pathstr(curpath)
          else
            unused(result,value,curpath)
          end
          curpath.pop
        end
      elsif curval.is_a?(Array)
        curval.each_index do |i|
          curpath << i
          if curval[i].nil?
            result << ConfigParser.pathstr(curpath)
          else
            unused(result,curval[i],curpath)
          end
          curpath.pop
        end
      else
        result << ConfigParser.pathstr(curpath)
      end

      result
    end
  end
end

