#!/usr/bin/ruby

require 'optparse'
require 'shellwords'
require 'rubygems'
require 'net/ssh'
require 'net/ssh/multi'
require 'socket'
require 'tempfile'
require 'securerandom'

start = Time.now

options = {
  :port => 10000,
  :output => "/tmp/output",
  :buffersize => 1750*64 #1460*64
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby #{__FILE__} [options]"
  opts.separator ""
  opts.separator "Specific options : "
  opts.on("-i", "--input FILE", "input file") { |v| options[:input] = v }
  opts.on("-o", "--output [FILE]", "output file") { |v| options[:output] = v }
  opts.on("-O", "--outputcmd [CMD]", "output command") { |v| options[:outputcmd] = v }
  opts.on("-b", "--buffersize SIZE", "buffer sise") { |v| options[:buffersize] = v }
  opts.on("-p", "--port PORT", "start port") { |v| options[:port] = v }
  opts.on("-c", "--check", "check the report")  { |v| options[:check] = v }
  opts.on("-C", "--[no-]checkmd5", "check md5sum") { |v| options[:checkmd5] = v }
  opts.on("-n", "--nodefile FILE", "node file") { |v| options[:nodefile] = v }
  opts.on("-s", "--[no-]sort", "sort the node file") { |v| options[:sort] = v }
  opts.on("-v", "--[no-]verbose", "run verbosely") { |v| options[:verbose] = v }
  opts.separator ""
  opts.separator "Common options :"
  opts.on_tail("-h", "--help", "show this message") do
    puts opts
    exit
  end
end.parse!

# GENERATES TEMP FILE
secureRandom = SecureRandom.hex
fountainPath = "/tmp/kascade" + secureRandom + "fountain.rb"
nodesPath = "/tmp/kascade" + secureRandom + "nodefile"
reportPath = "/tmp/kascade" + secureRandom + "report"

# READS NODEFILE
begin
  nodes = File.readlines(options[:nodefile])
rescue
  raise "Error : specified nodefile does not exists"
end

if options[:sort]
  nodes2 = []
  nodes.each do |n|
    clusterAndNode, siteName = n.split(".")
    clusterName, nodeNumber = clusterAndNode.split("-")
    while nodeNumber && nodeNumber.size < 3
      nodeNumber.insert(0, "0")
    end
    if nodeNumber
      nodeNumber.insert(0, "-")
    else
      nodeNumber = ""
    end
    nodes2 << siteName + "." + clusterName + nodeNumber
  end
  nodes2.sort!
  nodes = []
  nodes2.each do |n|
    siteName, clusterAndNode = n.split(".")
    clusterName, nodeNumber = clusterAndNode.split("-")
    if nodeNumber
      nodeNumber = nodeNumber.to_i.to_s
      nodeNumber.insert(0, "-")
    else
      nodeNumber = ""
    end
    nodes << clusterName + nodeNumber + "." + siteName + ".grid5000.fr"
  end
end

i = 0
nodesPorts = nodes.map do |line| 
  port = options[:port].to_i + i + 1
  i += 1
  line = line.chomp + ":#{port}"
end
nodesPorts = nodesPorts.unshift("#{Socket.gethostname}:#{options[:port]}").join("\n")
nodesPorts = Shellwords.escape(nodesPorts)


# FIRST FOUNTAIN
fountain = Shellwords.escape(File.read(__FILE__).split(/^# FOUNTAIN/)[1])
cmd = "echo #{fountain} > fountain.rb" 
system(cmd)
cmd = "echo #{nodesPorts} > #{nodesPath}"
system(cmd)

# REPORT SERVER
report = []
report_thr = Thread.new {
  reportPiece = ""
  server = TCPServer.new(options[:port])
  while reportPiece != "end" do
    Thread.start(server.accept) do |reportSock|
      reportPiece = reportSock.read
      if reportPiece != "end"
        puts "report received : " + reportPiece
        report << reportPiece
      end
      reportSock.close
    end
  end
}

# ALL FOUNTAINS
verbose = options[:verbose] ? "--verbose" : "--no-verbose"
Net::SSH::Multi.start do |session|
  nodes.each { |node| session.use(node) }
  time = Time.now
  cmd = "echo #{fountain} > #{fountainPath} && echo #{nodesPorts} > #{nodesPath}"
  session.exec(cmd)
  session.loop
  puts "HOST : " + Socket.gethostname
  time = Time.now - time
  puts "script forwarded in #{time}s" if options[:verbose]
  cmd = "ruby #{fountainPath} -o #{options[:output]} -O \"#{options[:outputcmd]}\" -b #{options[:buffersize]} -s #{File.size(options[:input])} -n #{nodesPath} #{verbose}"
  session.exec(cmd)
  start_thr = Thread.new {
    cmd = "ruby fountain.rb -i #{options[:input]} -o #{options[:output]} -O \"#{options[:outputcmd]}\" -b #{options[:buffersize]} -s #{File.size(options[:input])} -n #{nodesPath} #{verbose}"
    time = Time.now
    system(cmd)
  }
  session.loop
  start_thr.join
  time = Time.now - time
  totalTime = Time.now - start
  puts "KASCADE :"
  puts "\tFILE\t\t:\t#{options[:input]}"
  puts "\tSIZE\t\t:\t#{File.size(options[:input])} bytes"
  puts "\tNODES\t\t:\t#{nodes.length}"
  puts "\tTRANSFER TIME\t:\t#{time} seconds"
  puts "\tTOTAL TIME\t:\t#{totalTime} seconds"
  if !report.empty?
    report.uniq!
    puts "#{report.length} errors has been reported, creating a report file : " + reportPath
    reportFile = File.new(reportPath, "w")
    reportFile.write(report.join("\n"))   
    reportFile.close
  end
  if options[:check]
    nodes.map { |node| node.chomp! }
    nodes.each do |node|
      if report.include?(node)
        puts node + "\t--\tNOT OK"
      else
        puts node + "\t--\tOK"
      end
    end
  end
  if options[:checkmd5]
    if options[:outputcmd]
      puts "Can't check MD5 Sum when output command is given"
    else
      ref = `md5sum #{options[:input]}`
      puts "\nReference MD5 Sum : #{ref}"
      cmd = "md5sum #{options[:output]}"
      session.exec(cmd)
      session.loop
    end
  end
end


=begin
# FOUNTAIN

#!/usr/bin/ruby

require 'socket'
require 'optparse'
require 'open3'

def connectClient(nodes,ports,index,verbose)
  client = nil
  attempts = 0
  while !client && nodes[index]
    begin
      client = TCPSocket.new(nodes[index], ports[index])
    rescue => e
      puts "failed to connect to #{nodes[index]} with ports #{ports[index]}" if verbose
      attempts += 1
      if attempts < 10
        puts "next attempt in 1s" if verbose
        sleep(1)
      else
        puts "reporting #{nodes[index]}..." if verbose
        reportClient = TCPSocket.new(nodes[0], ports[0])
        reportClient.write(nodes[index])
        reportClient.close
        index += 1
        attempts = 0
      end
    end
  end
  return client, index
end

def stack(list, e, max)
  if list.length == max
    list = list.drop(1)
  elsif list.length > max
    raise "stack has become too large!"
  end
  list << e
end

options = {}
OptionParser.new do |opts|
  opts.on("-i", "--input [FILE]", "input file") { |v| options[:input] = v }
  opts.on("-o", "--output [FILE]", "output file") { |v| options[:output] = v }
  opts.on("-O", "--outputcmd [CMD]", "output command") { |v| options[:outputcmd] = v }
  opts.on("-b", "--buffersize SIZE", "buffer size") { |v| options[:buffersize] = v.to_i }
  opts.on("-s", "--filesize SIZE", "file size") { |v| options[:filesize] = v.to_i }
  opts.on("-n", "--nodefile FILE", "node file") { |v| options[:nodefile] = v }
  opts.on("-v", "--[no-]verbose", "run verbosely") { |v| options[:verbose] = v }
end.parse!

MAX_CHUNKS = 63
nodes = []
ports = []
index = 0
sever = nil
client = nil
recoverPoint = 0
nbChunks = 0
lastChunks = []
bytes = 0
lastNode = false
fin = false
clientRecoverMode = false
serverRecoverMode = false

File.readlines(options[:nodefile]).map do |line|
  node, port = line.split(":")
  nodes << node
  ports << port.to_i
end
index = nodes.index(Socket.gethostname)

# OPEN STREAMS
if !options[:input]
  if options[:outputcmd] != ""
    file,a,b = Open3.popen3(options[:outputcmd])
    raise "operation failed : " + options[:outputcmd] if !file
  else
    file = File.open(options[:output], "w")
    raise "failed to create " + options[:output] if !file
  end
  server = TCPServer.new(ports[index])
  puts "TCPServer open on port #{ports[index]}" if options[:verbose]
  stream = server.accept
else
  stream = File.open(options[:input], "r")
end
client, nextIndex = connectClient(nodes, ports, index.next, options[:verbose])
if client
  puts "connected to #{nodes[nextIndex]}" if options[:verbose]
else
  puts "last node of the chain" if options[:verbose]
  lastNode = true
end


# FILE TRANSMISSION

while !fin
  buffer = stream.read(options[:buffersize])
  if buffer
    begin
      client.write(buffer) if client
    rescue
      puts "Failed to send data to #{nodes[nextIndex]} -- now switching to recover mode" if options[:verbose]
      reportClient = TCPSocket.new(nodes[0], ports[0])
      reportClient.write(nodes[nextIndex])
      reportClient.close
      clientRecoverMode = true
      while clientRecoverMode
        client.close
        client, nextIndex = connectClient(nodes, ports, nextIndex.next, options[:verbose])
        if client
          puts "RECOVER CLIENT -- connected to #{nodes[nextIndex]}, waiting for its recover point" if options[:verbose]
          recoverPoint = client.recv(100).to_i
          puts "RECOVER CLIENT -- recover point received : #{recoverPoint} / #{nbChunks}" if options[:verbose]
          delta = nbChunks - recoverPoint
          raise "Not enough chunks saved for recover" if delta > MAX_CHUNKS
          begin
            lastChunks.last(delta).each do |chunk|
              client.write(chunk)
              puts "RECOVER CLIENT -- chunk resend ( #{chunk.length} bytes )" if options[:verbose]
            end
            puts "RECOVER CLIENT -- end" if options[:verbose]
            clientRecoverMode = false
          rescue => e
            puts "RECOVER CLIENT -- connexion lost with #{nodes[nextIndex]}" if options[:verbose]
            reportClient = TCPSocket.new(nodes[0], ports[0])
            reportClient.write(nodes[nextIndex])
            reportClient.close
          end
        else
          puts "RECOVER CLIENT -- new last node" if options[:verbose]
          lastNode = true
          clientRecoverMode = false
        end
      end
      retry
    end
    nbChunks += 1
    lastChunks = stack(lastChunks, buffer, MAX_CHUNKS)
    bytes += buffer.length
    file.write(buffer) if file
  elsif bytes == options[:filesize]
    fin = true
    puts "Transmission complete ( #{nbChunks} chunks )" if options[:verbose]
    if lastNode
      reportClient = TCPSocket.new(nodes[0],ports[0])
      reportClient.write("end")
      reportClient.close
    end
  else
    puts "An error has occured ( #{bytes} / #{options[:filesize]} ) ( #{nbChunks} chunks ) -- now switching to Recover Mode" if options[:verbose]
    serverRecoverMode = true
    stream.close
    stream = server.accept
    puts "RECOVER SERVER -- connected" if options[:verbose]
    stream.send("#{nbChunks}", 0)
    puts "RECOVER SERVER -- recover points send to it : #{nbChunks}" if options[:verbose]
    serverRecoverMode = false
  end
end

# CLOSE STREAMS
stream.close
client.close if client
file.close if file
server.close if server

system("rm " + options[:nodefile] + " " + __FILE__)

# FOUNTAIN
=end
