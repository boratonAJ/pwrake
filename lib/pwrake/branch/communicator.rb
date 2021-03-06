module Pwrake

class CommChannel

  def initialize(host,id,queue,writer,ios=[])
    @host = host
    @id = id
    @queue = queue
    @writer = writer
    @ios = ios
  end

  attr_reader :host, :id

  def put_line(s)
    if $cause_fault
      $cause_fault = nil
      Log.warn("closing writer io caller=\n#{caller.join("\n")}")
      @ios.each{|io| io.close}
    end
    @writer.put_line(s,@id)
  end

  def get_line
    @queue.deq
  end

  def halt
    @queue.halt
    @writer.halt
  end
end

class Communicator

  class ConnectError < IOError; end

  attr_reader :id, :host, :ncore, :channel
  attr_reader :reader, :writer, :handler
  attr_reader :shells

  def initialize(set,id,host,ncore,selector,option)
    @set = set
    @id = id
    @host = host
    @ncore = @ncore_given = ncore
    @selector = selector
    @option = option
    @shells = {}
  end

  def inspect
    "#<#{self.class} @id=#{@id},@host=#{@host},@ncore=#{@ncore}>"
  end

  def new_channel
    i,q = @reader.new_queue
    CommChannel.new(@host,i,q,@writer,[@ior,@iow,@ioe])
  end

  def connect(worker_code)
    rb_cmd = "ruby -e 'eval ARGF.read(#{worker_code.size})'"
    if ['localhost','localhost.localdomain','127.0.0.1'].include? @host
    #if /^localhost/ =~ @host
      cmd = rb_cmd
    else
      cmd = "ssh -x -T #{@option[:ssh_option]} #{@host} \"#{rb_cmd}\""
    end
    #
    @ior,w0 = IO.pipe
    @ioe,w1 = IO.pipe
    r2,@iow = IO.pipe
    @pid = Kernel.spawn(cmd,:pgroup=>true,:out=>w0,:err=>w1,:in=>r2)
    w0.close
    w1.close
    r2.close
    sel = @set.selector
    @reader = NBIO::MultiReader.new(sel,@ior)
    @rd_err = NBIO::Reader.new(sel,@ioe)
    @writer = NBIO::Writer.new(sel,@iow)
    @handler = NBIO::Handler.new(@reader,@writer,@host)
    #
    @writer.write(worker_code)
    @writer.write(Marshal.dump(@ncore))
    @writer.write(Marshal.dump(@option))
    # read ncore
    while s = @reader.get_line
      if /^ncore:(.*)$/ =~ s
        a = $1
        Log.debug "ncore=#{a} @#{@host}"
        if /^(\d+)$/ =~ a
          @ncore = $1.to_i
          return false
        else
          raise ConnectError, "invalid for ncore: #{a.inspect}"
        end
      else
        return false if !common_line(s)
      end
    end
    raise ConnectError, "fail to connect #{cmd.inspect}"
  rescue => e
    dropout(e)
  end

  def common_line(s)
    x = "Communicator#common_line(id=#{@id},host=#{@host})"
    case s
    when /^heartbeat$/
      Log.debug "#{x}: #{s.inspect}"
      @selector.heartbeat(@reader.io)
    when /^exited$/
      Log.debug "#{x}: #{s.inspect}"
      return false
    when /^log:(.*)$/
      Log.info "#{x}: log>#{$1}"
    when String
      Log.warn "#{x}: out>#{s.inspect}"
    when Exception
      Log.warn "#{x}: err>#{s.class}: #{s.message}"
      dropout(s)
      return false
    else
      raise ConnectError, "#{x}: invalid for read: #{s.inspect}"
    end
    true
  end

  def finish_shells
    @shells.keys.each{|sh| sh.finish_task_q}
  end

  def dropout(exc=nil)
    # Error output
    err_out = []
    begin
      finish_shells
      @handler.exit
      while s = @rd_err.get_line
        err_out << s
      end
    rescue => e
      m = Log.bt(e)
      #$stderr.puts m
      Log.error(m)
    end
    # Error output
    if !err_out.empty?
      $stderr.puts err_out.join("\n")
      Log.error((["process error output:"]+err_out).join("\n "))
    end
    # Exception
    if exc
      m = Log.bt(exc)
      #$stderr.puts m
      Log.error m
    end
  ensure
    @set.delete(self)
  end

  def finish
    @iow.close
    while s=@ior.gets
      puts "out=#{s.chomp}"
    end
    while s=@ioe.gets
      puts "err=#{s.chomp}"
    end
  end

end
end
