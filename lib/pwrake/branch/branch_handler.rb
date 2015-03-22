
module Pwrake

  class BranchHandler

    RE_ID='\d+'

    def initialize(queue)
      @queue = queue
      @tasks = []
    end

    def on_read(io)
      s = io.gets
      #p s
      # receive command from main pwrake
      case s
      when /^(\d+):(.+)$/o
        id, tname = $1,$2
        task = Rake.application[tname]
        @tasks.push(task)

      when /^end_task_list$/o
        @queue.enq(@tasks)
        @tasks.clear

      when /^exit_connection$/o
        p s
        #@queue.enq([false])
        #@queue.finish
        Util.dputs "branch:exit_connection"
        return true

      when /^kill:(.*)$/o
        sig = $1
        # Util.puts "branch:kill:#{sig}"
        Kernel.exit
        return true
      else
        puts "Invalild item: #{s}"
      end
      #resume
      return false
    end

  end
end
