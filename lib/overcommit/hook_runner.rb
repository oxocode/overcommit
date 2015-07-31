module Overcommit
  # Responsible for loading the hooks the repository has configured and running
  # them, collecting and displaying the results.
  class HookRunner
    # @param config [Overcommit::Configuration]
    # @param logger [Overcommit::Logger]
    # @param context [Overcommit::HookContext]
    # @param printer [Overcommit::Printer]
    def initialize(config, logger, context, printer)
      @config = config
      @log = logger
      @context = context
      @printer = printer
      @hooks = []
    end

    # Loads and runs the hooks registered for this {HookRunner}.
    def run
      # ASSUMPTION: we assume the setup and cleanup calls will never need to be
      # interrupted, i.e. they will finish quickly. Should further evidence
      # suggest this assumption does not hold, we will have to separately wrap
      # these calls to allow some sort of "are you sure?" double-interrupt
      # functionality, but until that's deemed necessary let's keep it simple.
      InterruptHandler.isolate_from_interrupts do
        # Load hooks before setting up the environment so that the repository
        # has not been touched yet. This way any load errors at this point don't
        # result in Overcommit leaving the repository in a bad state.
        load_hooks

        # Setup the environment without automatically calling
        # `cleanup_environment` on an error. This is because it's possible that
        # the `setup_environment` code did not fully complete, so there's no
        # guarantee that `cleanup_environment` will be able to accomplish
        # anything of value. The safest thing to do is therefore nothing in the
        # unlikely case of failure.
        @context.setup_environment

        begin
          run_hooks
        ensure
          @context.cleanup_environment
        end
      end
    end

    private

    attr_reader :log

    def run_hooks
      if @hooks.any?(&:enabled?)
        @printer.start_run

        interrupted = false
        run_failed = false
        run_warned = false

        @hooks.each do |hook|
          hook_status = run_hook(hook)

          run_failed = true if hook_status == :fail
          run_warned = true if hook_status == :warn

          if hook_status == :interrupt
            # Stop running any more hooks and assume a bad result
            interrupted = true
            break
          end
        end

        print_results(run_failed, run_warned, interrupted)

        !(run_failed || interrupted)
      else
        @printer.nothing_to_run
        true # Run was successful
      end
    end

    # @param failed [Boolean]
    # @param warned [Boolean]
    # @param interrupted [Boolean]
    def print_results(failed, warned, interrupted)
      if interrupted
        @printer.run_interrupted
      elsif failed
        @printer.run_failed
      elsif warned
        @printer.run_warned
      else
        @printer.run_succeeded
      end
    end

    def run_hook(hook)
      return if should_skip?(hook)

      @printer.start_hook(hook)

      status, output = nil, nil

      begin
        # Disable the interrupt handler during individual hook run so that
        # Ctrl-C actually stops the current hook from being run, but doesn't
        # halt the entire process.
        InterruptHandler.disable_until_finished_or_interrupted do
          status, output = hook.run_and_transform
        end
      rescue => ex
        status = :fail
        output = "Hook raised unexpected error\n#{ex.message}\n#{ex.backtrace.join("\n")}"
      rescue Interrupt
        # At this point, interrupt has been handled and protection is back in
        # effect thanks to the InterruptHandler.
        status = :interrupt
        output = 'Hook was interrupted by Ctrl-C; restoring repo state...'
      end

      @printer.end_hook(hook, status, output)

      status
    end

    def should_skip?(hook)
      return true unless hook.enabled?

      if hook.skip?
        if hook.required?
          @printer.required_hook_not_skipped(hook)
        else
          # Tell user if hook was skipped only if it actually would have run
          @printer.hook_skipped(hook) if hook.run?
          return true
        end
      end

      !hook.run?
    end

    def load_hooks
      require "overcommit/hook/#{@context.hook_type_name}/base"

      @hooks += HookLoader::BuiltInHookLoader.new(@config, @context, @log).load_hooks

      # Load plugin hooks after so they can subclass existing hooks
      @hooks += HookLoader::PluginHookLoader.new(@config, @context, @log).load_hooks
    rescue LoadError => ex
      # Include a more helpful message that will probably save some confusion
      message = 'A load error occurred. ' +
        if @config['gemfile']
          "Did you forget to specify a gem in your `#{@config['gemfile']}`?"
        else
          'Did you forget to install a gem?'
        end

      raise Overcommit::Exceptions::HookLoadError,
            "#{message}\n#{ex.message}",
            ex.backtrace
    end
  end
end
