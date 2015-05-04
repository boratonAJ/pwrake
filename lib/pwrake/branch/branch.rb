module Pwrake

  class Branch

    def initialize(opts,r,w)
      @options = opts
      @queue = {}  # worker_id => FiberQueue.new
      @timeout = @options['HEARTBEAT_TIMEOUT']
      @exit_cmd = "exit_connection"
      @shells = []
      @ior = r
      @iow = w
      @wk_comm = {}
      @shell_start_interval = @options['SHELL_START_INTERVAL']
    end

    # Rakefile is loaded after 'init' before 'run'

    def run
      @dispatcher = IODispatcher.new
      @comm_set = CommunicatorSet.new
      setup_shells
      setup_fibers
      bh = BranchHandler.new(@queue,@iow,@comm_set)
      @dispatcher.attach_handler(@ior,bh)
      @dispatcher.event_loop(@timeout)
    end

    attr_reader :logger

    def init_logger
      logfile = @options['LOGFILE']
      if logfile
        if dir = @options['LOG_DIR']
          ::FileUtils.mkdir_p(dir)
          logfile = File.join(dir,logfile)
        end
        @logger = Logger.new(logfile)
      else
        @logger = Logger.new($stderr)
      end

      if @options['DEBUG']
        @logger.level = Logger::DEBUG
      elsif @options['TRACE']
        @logger.level = Logger::INFO
      else
        @logger.level = Logger::WARN
      end
    end

    def setup_shells
      s = @ior.gets
      raise if s.chomp != "begin_worker_list"

      if fn = @options["PROFILE"]
        if dir = @options['LOG_DIR']
          ::FileUtils.mkdir_p(dir)
          fn = File.join(dir,fn)
        end
        Shell.profiler.open(fn,@options['GNU_TIME'],@options['PLOT_PARALLELISM'])
      end

      while s = @ior.gets
        s.chomp!
        break if s == "end_worker_list"
        if /^(\d+):(\S+) (\d+)?$/ =~ s
          id, host, ncore = $1,$2,$3
          ncore &&= ncore.to_i
          comm = WorkerCommunicator.new(id,host,ncore,@dispatcher,@options.worker_option)
          @wk_comm[comm.ior] = comm
          @comm_set << comm
          @dispatcher.attach_communicator(comm)
          @queue[id] = FiberQueue.new
        end
      end

      # receive ncore from worker node
      io_list = @wk_comm.keys
      io_fail = []
      IODispatcher.event_once(io_list,@timeout) do |io|
        if io.eof?
          io_fail << io
        else
          s = io.gets
          if /ncore:(\d+)/ =~ s
            @wk_comm[io].set_ncore($1.to_i)
          end
        end
      end
      if !(io_list.empty? && io_fail.empty?)
        t = io_list.map{|io| @wk_comm[io].host}.join(',')
        f = io_fail.map{|io| @wk_comm[io].host}.join(',')
        raise RuntimeError, "error in connection to worker: fail:(#{f}),timeout:(#{t})"
      end

      # ncore
      @wk_comm.each_value do |comm|
        # set WorkerChannel#ncore at Master
        @iow.puts "ncore:#{comm.id}:#{comm.ncore}"
        @iow.flush
      end
      @iow.puts "ncore:done"
      @iow.flush

      # pass env
      @wk_comm.each_value do |comm|
        comm.pass_env
      end

      # shells
      @shells = []
      @wk_comm.each_value do |comm|
        comm.ncore.times do
          @shells << shl = Shell.new(comm,@options.worker_option)
        end
      end
    end

    def setup_fibers
      @fiber_list = @shells.map{|shl| create_fiber(shl)}

      # start fiber
      @fiber_list.each do |fb|
        fb.resume
        sleep @shell_start_interval
      end
      Log.debug "all fiber started"

      waiters = {}
      @shells.each{|shl| waiters[shl.id]=true}

      # receive open notice from worker
      @dispatcher.event_loop_block do |io|
        s = io.gets
        case s
        when /^open:(\d+)$/
          waiters.delete($1)
        when /^worker_end$/
          wk = @wk_comm[io]
          m = "worker_end id=#{wk.id} host=#{wk.host}"
          Log.warn m
          $stderr.puts m
          @dispatcher.detach_io(io)
          @wk_comm.delete(io)
        when /^heartbeat$/
          @dispatcher.heartbeat(@wk_comm[io])
        else
          m = "worker_out: #{s}"
          Log.fatal m
          raise RuntimeError, m
        end
        break if waiters.empty?
      end

      # setup end
      @wk_comm.values.each do |comm|
        comm.send_cmd "setup_end"
      end

      Log.debug "branch setup end"
      @iow.puts "branch_setup:done"
      @iow.flush
    end

    def create_fiber(shell)
      Fiber.new do
        shell.start
        Log.debug "shell start id=#{shell.id} host=#{shell.host}"
        comm = shell.communicator
        queue = @queue[comm.id]
        begin
          while task_str = queue.deq
            tm = Time.now
            if /^(\d+):(.*)$/ =~ task_str
              task_id, task_name = $1.to_i, $2
            else
              raise RuntimeError, "invalid task_str: #{task_str}"
            end
            shell.set_current_task(task_id,task_name)
            task = Rake.application[task_name]
            begin
              task.execute if task.needed?
            rescue Exception=>e
              if task.kind_of?(Rake::FileTask) && File.exist?(task.name)
                handle_failed_target(task.name)
              end
              @iow.puts "taskfail:#{shell.id}:#{task.name}"
              @iow.flush
              raise e
            end
            @iow.puts "taskend:#{shell.id}:#{task.name}"
            @iow.flush
            #Log.debug "taskend:#{shell.id}:#{task.name}:time=#{Time.now-tm}"
          end
        ensure
          Log.debug "closing shell id=#{shell.id}"
          shell.close
        end
      end
    end

    def handle_failed_target(name)
      case @options['FAILED_TARGET']
      when /rename/i, NilClass
        dst = name+"._fail_"
        ::FileUtils.mv(name,dst)
        msg = "Rename failed target file '#{name}' to '#{dst}'"
        $stderr.puts(msg)
        Log.warn(msg)
      when /delete/i
        ::FileUtils.rm(name)
        msg = "Delete failed target file '#{name}'"
        $stderr.puts(msg)
        Log.warn(msg)
      when /leave/i
      end
    end

    def finish
      Log.debug "#{self.class}#finish"
      @comm_set.close_all
      @comm_set.each do |comm|
        while s=comm.gets
          Log.debug "comm.id=#{comm.id}> #{s}"
        end
      end
      @dispatcher.finish

      @iow.puts "branch_end"
      @iow.flush
      @ior.close
      @iow.close
    end

  end # Pwrake::Branch
end
