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
      results.each_pair do |host,pids|
        pids.each_pair do |pid,values|
          affected = false
          ret.each_pair do |k,v|
            if values.eql?(v)
              k << [ host, pid ]
              affected = true
              break
            end
          end
          ret[[[host,pid]]] = values unless affected
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

  # A Hash where the keyring is based on the host/pid
  class Result < Hash
    attr_reader :content

    def initialize(content={})
      @content = content
    end

    def free()
      self.each_pair do |host,pids|
        pids.each_value do |val|
          val.clear if val.is_a?(Array) or val.is_a?(Hash)
        end
        pids.clear
      end
      self.clear
    end

    def add(host,pid,val,concatval=false)
      raise unless val.is_a?(Hash)
      self.store(host,{}) unless self[host]
      self[host].store(pid,{}) unless self[host][pid]
      val.each_key do |k|
        if concatval
          self[host][pid][k] = '' unless self[host][pid][k]
          self[host][pid][k] << val[k]
          self[host][pid][k] << concatval
        else
          self[host][pid][k] = [] unless self[host][pid][k]
          self[host][pid][k] << val[k]
        end
      end
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

    def initialize(type,template=nil,concat=false)
      @type = type
      @template = template
      @concat = concat
    end

    def free
      @type = nil
      @template = nil
    end

    def parse(string)
      ret = Result.new
      if @template and string and !string.empty?
        regexp = /^#{@type.to_s}#{SEPESCAPED}(\d+)#{SEPESCAPED}(#{HOSTNAME_REGEXP})#{SEPESCAPED}(.+)$/
        string.each_line do |line|
          if regexp =~ line
            ret.add(
              Regexp.last_match(2),
              Regexp.last_match(1),
              @template.parse(Regexp.last_match(3)),
              (@concat ? $/ : false)
            )
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
      super(:output,template,true)
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
        if self[opt]
          if self[opt].is_a?(String)
            ret << self[opt] unless self[opt].empty?
          else
            ret << self[opt].to_s
          end
        end
        ret
      end
    end
  end

  class Hostlist
    def initialize(hostlist)
      @hostlist=hostlist
    end

    def free
      @hostlist = nil
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

    def to_a
      if @hostlist.is_a?(Array)
        @hostlist
      elsif @hostlist.is_a?(String)
        File.read(@hostlist).split("\n").uniq
      end
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

    def run!(opts = {})
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
      hosts = @hostlist.to_a
      outputs_size = opts[:outputs_size] || 0
      @status, @stdout, @stderr, emptypipes = @exec.wait(
        :stdout_size => outputs_size * hosts.size,
        :stderr_size => outputs_size * hosts.size
      )

      unless @status.success?
        @curthread = nil
        return false
      end

      unless emptypipes
        @curthread = nil
        @stderr = "Too much data on the TakTuk command's stdout/stderr"
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
      @curthread.kill if @curthread.alive?
      unless @exec.nil?
        @exec.kill
        @exec = nil
      end
      free!()
    end

    def free!()
      @binary = nil
      @options = nil
      if @streams
        @streams.each_value do |stream|
          stream.free if stream
          stream = nil
        end
      end
      @hostlist.free if @hostlist
      @hostlist = nil
      @commands = nil
      @args = nil
      @stdout = nil
      @stderr = nil
      @status = nil
      @exec = nil
      @curthread = nil
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

###
# Execution samples:
###
#   taktuk('hostfile',:connector => 'ssh -A', :self_propagate => true).broadcast_exec['hostname'].run!
###
#   taktuk(['node-1','node-2'],:dynamic => 3).broadcast_put['myfile']['dest'].run!
###
#   taktuk(nodes).broadcast_exec['hostname'].seq!.broadcast_exec['df'].run!
###
#   taktuk(nodes).broadcast_exec['cat - | fdisk'].seq!.broadcast_input_file['fdiskdump'].run!
###
#   tak = taktuk(nodes)
#   tak.broadcast_exec['hostname']
#   tak.seq!.broadcast_exec['df']
#   tak.streams[:output] => OutputStream.new(Template[:line,:rank]),
#   tak.streams[:info] => ConnectorStream.new(Template[:command,:line])
#   tak.run!
###
def taktuk(*args)
  TakTuk::TakTuk.new(*args)
end
