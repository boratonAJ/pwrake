module Pwrake

  InvocationChain = Rake::InvocationChain
  TaskArguments = Rake::TaskArguments

  module TaskAlgorithm

    attr_reader :wrapper
    attr_reader :subsequents
    attr_reader :arguments

    def pw_search_tasks(args)
      Log.debug "#{self.class}#pw_search_tasks start, args=#{args.inspect}"
      tm = Time.now
      task_args = TaskArguments.new(arg_names, args)
      #timer = Timer.new("search_task")
      #h = application.pwrake_options['HALT_QUEUE_WHILE_SEARCH']
      #application.task_queue.synchronize(h) do
	search_with_call_chain(nil, task_args, InvocationChain::EMPTY)
      #end
      #timer.finish
      Log.debug "#{self.class}#pw_search_tasks end #{Time.now-tm}"
    end

    # Same as search, but explicitly pass a call chain to detect
    # circular dependencies.
    def search_with_call_chain(subseq, task_args, invocation_chain) # :nodoc:
      new_chain = InvocationChain.append(self, invocation_chain)
      @lock.synchronize do
        if application.options.trace
          #Log.info "** Search #{name} #{format_search_flags}"
          application.trace "** Search #{name} #{format_search_flags}"
        end

        return true if @already_finished # <<--- competition !!!
        @subsequents ||= []
        @subsequents << subseq if subseq # <<--- competition !!!

        if ! @already_searched
          @already_searched = true
          @arguments = task_args
          @wrapper = TaskWrapper.new(self,task_args)
          if @prerequisites.empty?
            @unfinished_prereq = {}
          else
            search_prerequisites(task_args, new_chain)
          end
          #check_and_enq
          if @unfinished_prereq.empty?
            application.task_queue.enq(@wrapper)
          end
        end
        return false
      end
    rescue Exception => ex
      add_chain_to(ex, new_chain)
      raise ex
    end

    # Search all the prerequisites of a task.
    def search_prerequisites(task_args, invocation_chain) # :nodoc:
      @unfinished_prereq = {}
      @prerequisites.each{|t| @unfinished_prereq[t]=true}
      prerequisite_tasks.each { |prereq|
        prereq_args = task_args.new_scope(prereq.arg_names)
        if prereq.search_with_call_chain(self, prereq_args, invocation_chain)
          @unfinished_prereq.delete(prereq.name)
        end
      }
    end

    # Format the trace flags for display.
    def format_search_flags
      flags = []
      flags << "finished" if @already_finished
      flags << "first_time" unless @already_searched
      flags << "not_needed" unless needed?
      flags.empty? ? "" : "(" + flags.join(", ") + ")"
    end
    private :format_search_flags

    def pw_enq_subsequents
      t = Time.now
      #h = application.pwrake_options['HALT_QUEUE_WHILE_SEARCH']
      #application.task_queue.synchronize(h) do
        @subsequents.each do |t|        # <<--- competition !!!
          if t && t.check_prereq_finished(self.name)
            application.task_queue.enq(t.wrapper)
          end
        end
      #end
      @already_finished = true        # <<--- competition !!!
    end

    def check_prereq_finished(preq_name=nil)
      @unfinished_prereq.delete(preq_name)
      @unfinished_prereq.empty?
    end

    def pw_set_ncore(n)
      n ||= 1
      if n.kind_of?(Integer)
        @n_used_cores = n
      else
        raise ArgumentError, "Invalid for n_cores: #{n.inspect}"
      end
      self
    end

    def n_used_cores(max_cores=nil)
      n = @n_used_cores
      if max_cores
        if n > max_cores
          m = "n_task_cores=#{n} must be <= max_cores=#{max_cores}"
          Log.fatal m
          raise RuntimeError,m
        end
      else
        max_cores = 0
      end
      if n > 0
        return n
      else
        n += max_cores
        if n > 0
          @n_used_cores += max_cores
          return n
        else
          m = "n_task_cores=#{n} must be > 0"
          Log.fatal m
          raise RuntimeError,m
        end
      end
    end

  end
end
