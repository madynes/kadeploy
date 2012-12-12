require 'execute'

module TakTuk
  class Aggregator
    def initialize(criteria)
      @criteria = criteria
    end

    def self.[](criteria)
      self.new(criteria)
    end


    def visit(results)
      ret = {}
      results = results.compact!()
      results.each do |result|
        curval = result.dup
        @criteria.each do |criterion|
          curval.delete(criterion)
        end

        curkey = []
        @criteria.each do |criterion|
          curkey << result[criterion]
        end

        ok = false
        ret.each_pair do |critkeys,v|
          if curval == v
            critkeys << curkey
            ok = true
            break
          end
        end
        unless ok
        ret[[curkey]] = curval
        end
      end
      ret
    end
  end

  class DefaultAggregator < Aggregator
    def initialize
      super([:host,:pid])
    end
  end

  class Result < Hash
    attr_reader :content

    def initialize(content={})
      @content = content
    end

    def push(key,val)
      self.store(key,[]) unless self[key]
      self[key] << val
    end

    def compact!(excludelist=[:line])
      ret = []
      self.each_pair do |key,values|
        equals = true
        tmp = {}
        keys = values.first.keys
        values.each do |value|
          if value.keys == keys
            value.each_pair do |field,val|
              tmp[field] = [] unless tmp[field]
              tmp[field] << val if !tmp[field].include?(val) or excludelist.include?(field)
            end
          else
            equals = false
            break
          end
        end
        if equals
          # Clean 1 elem arrays
          tmp.each_pair do |k,v|
            tmp[k] = tmp[k][0] if tmp[k].size == 1
          end
          #self[key] = tmp
          ret << tmp
        end
      end
      ret
    end

    def aggregate(aggregator)
      aggregator.visit(self)
    end
  end

  class Stream
    attr_accessor :template

    SEPARATOR = '/'
    SEPESCAPED = Regexp.escape(SEPARATOR)
    IP_REGEXP = "(?:(?:[0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}"\
                "(?:[0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])"
    DOMAIN_REGEXP = "(?:(?:[a-zA-Z]|[a-zA-Z][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*"\
                "(?:[A-Za-z]|[A-Za-z][A-Za-z0-9\-]*[A-Za-z0-9])"
    HOSTNAME_REGEXP = "#{IP_REGEXP}|#{DOMAIN_REGEXP}"

    def initialize(type,template=nil)
      @type = type
      @template = template
    end

    def parse(string)
      ret = Result.new
      if @template
        string.each_line do |line|
          if /^#{@type.to_s}#{SEPESCAPED}(\d+)#{SEPESCAPED}(#{HOSTNAME_REGEXP})#{SEPESCAPED}(.+)$/ =~ line
            tmp = @template.parse(Regexp.last_match(3))
            tmp[:host] = Regexp.last_match(2)
            tmp[:pid] = Regexp.last_match(1)
            ret.push([tmp[:host],tmp[:pid]],tmp)
          end
        end
      end
      ret
    end

    def to_cmd
      #"#{@type.to_s}="\
      "\"$type#{SEPARATOR}$pid#{SEPARATOR}$host#{SEPARATOR}\""\
      "#{@template.to_cmd}.\"\\n\""
    end
  end

  class ConnectorStream < Stream
    def initialize(template)
      super(:connector,template)
    end
  end

  class OutputStream < Stream
    def initialize(template)
      super(:output,template)
    end
  end

  class ErrorStream < Stream
    def initialize(template)
      super(:error,template)
    end
  end

  class StatusStream < Stream
    def initialize(template)
      super(:status,template)
    end
  end

  class StateStream < Stream
    STATES = {
      :error => {
        3 => 'connection failed',
        5 => 'connection lost',
        7 => 'command failed',
        9 => 'numbering update failed',
        11 => 'pipe input failed',
        14 => 'file reception failed',
        16 => 'file send failed',
        17 => 'invalid target',
        18 => 'no target',
        20 => 'invalid destination',
        21 => 'destination not available anymore',
      },
      :progress => {
        0 => 'taktuk is ready',
        1 => 'taktuk is numbered',
        4 => 'connection initialized',
        6 => 'command started',
        10 => 'pipe input started',
        13 => 'file reception started',
      },
      :done => {
        2 => 'taktuk terminated',
        8 => 'command terminated',
        12 => 'pipe input terminated',
        15 => 'file reception terminated',
        19 => 'message delivered',
      }
    }

    def initialize(template)
      super(:state,template)
    end

    # type can be :error, :progress or :done
    def self.check?(type,state)
      return nil unless STATES[type]
      state = state.strip

      begin
        nb = Integer(state)
        STATES[type].keys.include?(nb)
      rescue
        STATES[type].values.include?(state.downcase!)
      end
    end

    def self.errmsg(nb)
      STATES.each_value do |typeval|
        return typeval[nb] if typeval[nb]
      end
    end
  end

  class MessageStream < Stream
    def initialize(template)
      super(:message,template)
    end
  end

  class InfoStream < Stream
    def initialize(template)
      super(:info,template)
    end
  end

  class TaktukStream < Stream
    def initialize(template)
      super(:taktuk,template)
    end
  end

  class Template
    SEPARATOR=':'
    attr_reader :fields

    def initialize(fields)
      @fields = fields
    end

    def self.[](*fields)
      self.new(fields)
    end

    def add(template)
      template.fields.each do |field|
        @fields << field unless fields.include?(field)
      end
      self
    end

    def to_cmd
      @fields.inject('') do |ret,field|
        ret + ".length(\"$#{field.to_s}\").\"#{SEPARATOR}$#{field.to_s}\""
      end
    end

    def parse(string)
      ret = {}
      curpos = 0
      @fields.each do |field|
        len,tmp = string[curpos..-1].split(SEPARATOR,2)
        leni = len.to_i
        raise ArgumentError.new('Command line output do not match the template') if tmp.nil?
        if leni <= 0
          ret[field] = ''
        else
          ret[field] = tmp.slice!(0..(leni-1))
        end
        curpos += len.length + leni + 1
      end
      ret
    end
  end

  class Options < Hash
    VALID = [
      'begin-group', 'connector', 'dynamic', 'end-group', 'machines-file',
      'login', 'machine', 'self-propagate', 'dont-self-propagate',
      'args-file', 'gateway', 'perl-interpreter', 'localhost',
      'send-files', 'taktuk-command', 'path-value', 'command-separator',
      'escape-character', 'option-separator', 'output-redirect',
      'worksteal-behavior', 'time-granularity', 'no-numbering', 'timeout',
      'cache-limit', 'window','window-adaptation','not-root','debug'
    ]

    def check(optname)
      ret = optname.to_s.gsub(/_/,'-').strip
      raise ArgumentError.new("Invalid TakTuk option '--#{ret}'") unless VALID.include?(ret)
      ret
    end

    def to_cmd
      self.keys.inject([]) do |ret,opt|
        ret << "--#{check(opt)}"
        ret << self[opt] if self[opt] and self[opt].is_a?(String) and !self[opt].empty?
        ret
      end
    end
  end

  class Hostlist
    def initialize(hostlist)
      @hostlist=hostlist
    end

    def exclude(node)
      @hostlist.remove(node) if @hostlist.is_a?(Array)
    end

    def to_cmd
      ret = []
      if @hostlist.is_a?(Array)
        @hostlist.each do |host|
          ret << '-m'
          ret << host
        end
      elsif @hostlist.is_a?(String)
        ret << '-f'
        ret << @hostlist
      end
      ret
    end
  end

  class Commands < Array
    TOKENS=[
      'broadcast', 'downcast', 'exec', 'get', 'put', 'input', 'data',
      'file', 'pipe', 'close', 'line', 'target', 'kill', 'message',
      'network', 'state', 'cancel', 'renumber', 'update', 'option',
      'synchronize', 'taktuk_perl', 'quit', 'wait', 'reduce'
    ]

    def <<(val)
      raise ArgumentError.new("'Invalid TakTuk command '#{val}'") unless check(val)
      super(val)
    end

    def check(val)
      if val =~ /^-?\[.*-?\]$|^;$/
        true
      elsif val.nil? or val.empty?
        false
      else
        tmp = val.split(' ',2)
        return false unless valid?(tmp[0])
        if !tmp[1].nil? and !tmp[1].empty?
          check(tmp[1])
        else
          true
        end
      end
    end

    def valid?(value)
      TOKENS.each do |token|
        return true if token =~ /^#{Regexp.escape(value)}.*$/
      end
      return false
    end

    def to_cmd
      self.inject([]) do |ret,val|
        if val =~ /^\[(.*)\]$/
          ret += ['[',Regexp.last_match(1).strip,']']
        else
          ret += val.split(' ')
        end
      end
    end
  end

  class TakTuk
    attr_accessor :streams,:binary
    attr_reader :stdout,:stderr,:status, :args, :exec

    def initialize(hostlist,options = {:connector => 'ssh'})
      @binary = 'taktuk'
      @options = Options[options]

      @streams = {
        :output => OutputStream.new(Template[:line]),
        :error => ErrorStream.new(Template[:line]),
        :status => StatusStream.new(Template[:command,:line]),
        :connector => ConnectorStream.new(Template[:command,:line]),
        :state => StateStream.new(Template[:command,:line,:peer]),
        :info => nil,
        :message => nil,
        :taktuk => nil,
      }

      @hostlist = Hostlist.new(hostlist)
      @commands = Commands.new

      @args = nil
      @stdout = nil
      @stderr = nil
      @status = nil

      @exec = nil
      @curthread = nil
    end

    def opts!(opts={})
      @options = Options[opts]
    end

    def run!
      @curthread = Thread.current
      @args = []
      @args += @options.to_cmd
      @streams.each_pair do |name,stream|
        temp = (stream.is_a?(Stream) ? "=#{stream.to_cmd}" : '')
        @args << '-o'
        @args << "#{name.to_s}#{temp}"
      end
      @args += @hostlist.to_cmd
      @args += @commands.to_cmd

      @exec = Execute[@binary,*@args].run!
      @status, @stdout, @stderr = @exec.wait

      unless @status.success?
        @curthread = nil
        return false
      end

      results = {}
      @streams.each_pair do |name,stream|
        if stream.is_a?(Stream)
          results[name] = stream.parse(@stdout)
        else
          results[name] = nil
        end
      end

      @curthread = nil

      results
    end

    def kill!()
      @curthread.kill! if @curthread.alive?
      unless @exec.nil?
        @exec.kill
        @exec = nil
      end
    end

    def raw!(string)
      @commands << string.strip
      self
    end

    def seq!
      @commands << ';'
      self
    end

    def [](command,prefix='[',suffix=']')
      @commands << "#{prefix} #{command} #{suffix}"
      self
    end

    def method_missing(meth,*args)
      @commands << (meth.to_s.gsub(/_/,' ').strip.downcase)
      args.each do |arg|
        @commands.push(arg.strip.downcase)
      end
      self
    end
  end
end

def taktuk(*args)
  TakTuk::TakTuk.new(*args)
end
