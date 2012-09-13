# To be used as you're using Open3.popen3 in ruby 1.9.2
class Execute
  def self.do(*cmd,&block)
    in_r, in_w = IO::pipe
    in_w.sync = true

    out_r, out_w = IO::pipe
    err_r, err_w = IO::pipe

    child_io = [in_r,out_w,err_w]
    parent_io = [in_w,out_r,err_r]

    pid = fork {
      parent_io.each { |io| io.close }
      std = [STDIN, STDOUT, STDERR]
      std.each_index do |i|
        std[i].reopen(child_io[i])
        child_io[i].close
      end
      exec(*cmd)
    }

    wait_thr = Thread.new { Process.wait(pid); $? }
    wait_thr[:pid] = pid

    child_io.each { |io| io.close }
    result = [wait_thr, *parent_io]
    if defined? yield
      begin
        return yield(*result)
      ensure
        parent_io.each { |io| io.close unless io.closed? }
        wait_thr.join
      end
    end
    result
  end
end
