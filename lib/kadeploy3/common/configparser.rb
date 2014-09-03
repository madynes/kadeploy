require 'pathname'
require 'fileutils'
require 'open3'

module Kadeploy

module Configuration
  class ParserError < StandardError
  end

  ###
  # Sample file:
  ###
  # database:
  #   user: myser
  #   password: thepassword
  #   ip: 127.0.0.1
  # cache:
  #   size: 1234
  #   # default directory: /tmp
  #   # default strict: true
  # # default values for environments fields
  #
  ###
  # Parser
  ###
  # cp = Configuration::Parser.new(yamlstr)
  # conf = {:db=>{}, :cache=>{}, :env=>{}, :pxe => {}}
  # cp.parse('database',true) do
  #   # String with default value
  #   conf[:db][:user] = cp.value('user',String,nil,'defaultvalue')
  #   # Mandatory String
  #   conf[:db][:password] = cp.value('password',String)
  #   # String with multiple possible values
  #   conf[:db][:kind] = cp.value('kind',String,nil,['MySQL','PostGRE','Oracle'])
  #   # Regexp
  #   conf[:db][:ip] = cp.value('ip',String,'127.0.0.1',
  #     /\A\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3}\Z/
  #   )
  # end
  # cp.parse('cache',true) do
  #   # Integer with default value
  #   conf[:cache][:size] = cp.value('size',Fixnum,nil,100)
  #   # Directory that need to exist and be r/w
  #   conf[:cache][:directory] = cp.value('directory',String,'/tmp',
  #     {
  #       :type => 'dir',
  #       :readable => true,
  #       :writable => true,
  #       :create => true,
  #       :mode => 0700
  #     }
  #   )
  #   # Boolean
  #   conf[:cache][:strict] = cp.value('strict',[TrueClass,FalseClass],true)
  # end
  #
  # # Non-mandatory field
  # cp.parse('environments') do
  #   # Specification of a unix path
  #   conf[:env][:tar_dir] = cp.value('tarball_dir',String,'/tmp',Pathname)
  #   # Add a prefix to a value
  #   conf[:env][:user_dir] = cp.value('user_dir',String,'/tmp',
  #     {:type => 'dir', :prefix => '/home/'}
  #   )
  # end

  class Parser
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
      self.class.pathstr(@path + [val])
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
              yield(@val[fieldname],true)
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
            yield(nil,@val.has_key?(fieldname))
          end
        elsif mandatory
          if @val.nil?
            raise ParserError.new("The field is mandatory")
          else
            raise ParserError.new("The field has to be a Hash")
          end
        else
          yield(nil,false)
        end
      rescue ParserError => pe
        raise ArgumentError.new(
          self.class.errmsg(path(fieldname),pe.message)
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
      val = val.clone if hash[:const]
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
      if File.exist?(val)
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
      if args[:command]
        val = val.split(/\s+/).first||''
        if !val.empty? and !Pathname.new(val).absolute?
            # Since the command is launched in a shell and can be a script,
            # if the command cannot be found, skip further checkings
           val = `which '#{val}' 2>/dev/null`.strip
           return unless $?.success?
        end
      end

      if args[:prefix]
        tmp = Pathname.new(val)
        val.gsub!(val,File.join(args[:prefix],val)) if !tmp.absolute? and !val.empty?
      end
      val.gsub!(val,File.join(val,args[:suffix])) if args[:suffix]
      if File.exist?(val)
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

          if args[:executable]
            unless File.stat(val).executable?
              raise ParserError.new("The file '#{val}' is not executable")
            end
          end
        else
          raise ParserError.new("The file '#{val}' is not a regular file")
        end
      else
        unless val.empty?
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
    end

    def customcheck_dir(val, fieldname, args)
      return if args[:disable]
      val = File.join(args[:prefix],val) if args[:prefix] and !val.empty?
      val = File.join(val,args[:suffix]) if args[:suffix] and !val.empty?
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


    def parse(fieldname, mandatory=false, type=Hash,warns_if_empty=true)
      check_field(fieldname,mandatory,type) do |curval,provided|
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
              :provided => provided,
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
            :provided => provided,
          })
        end
        oldval.delete(fieldname) if (curval and curval.empty?) or (!warns_if_empty and provided)

        pop(oldval)
      end
    end

    # if no defaultvalue defined, field is mandatory
    def value(fieldname,type,defaultvalue=nil,expected=nil)
      ret = nil
      check_field(fieldname,defaultvalue.nil?,type) do |val,_|
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
      curval = @basehash if curval.nil?
      curpath = [] unless curpath

      if curval.is_a?(Hash)
        curval.each do |key,value|
          curpath << key
          if value.nil?
            result << self.class.pathstr(curpath)
          else
            unused(result,value,curpath)
          end
          curpath.pop
        end
      elsif curval.is_a?(Array)
        curval.each_index do |i|
          curpath << i
          if curval[i].nil?
            result << self.class.pathstr(curpath)
          else
            unused(result,curval[i],curpath)
          end
          curpath.pop
        end
      else
        result << self.class.pathstr(curpath)
      end

      result
    end
  end
end

end
