require 'instrumental/rack/middleware'
require 'instrumental/version'
require 'logger'
require 'thread'
require 'socket'
if RUBY_VERSION < "1.9"
  require 'system_timer'
else
  require 'timeout'
end


# Sets up a connection to the collector.
#
#  Instrumental::Agent.new(API_KEY)
module Instrumental
  class Agent
    BACKOFF = 2.0
    MAX_RECONNECT_DELAY = 15
    MAX_BUFFER = 5000
    REPLY_TIMEOUT = 10
    CONNECT_TIMEOUT = 20
    EXIT_FLUSH_TIMEOUT = 5

    attr_accessor :host, :port, :synchronous, :queue
    attr_reader :connection, :enabled

    def self.logger=(l)
      @logger = l
    end

    def self.logger
      if !@logger
        @logger = Logger.new(STDERR)
        @logger.level = Logger::WARN
      end
      @logger
    end

    def self.all
      @agents ||= []
    end

    def self.new(*args)
      inst = super
      all << inst
      inst
    end

    # Sets up a connection to the collector.
    #
    #  Instrumental::Agent.new(API_KEY)
    #  Instrumental::Agent.new(API_KEY, :collector => 'hostname:port')
    def initialize(api_key, options = {})
      default_options = {
        :collector  => 'instrumentalapp.com:8000',
        :enabled    => true,
        :test_mode  => false,
        :synchronous => false
      }
      options   = default_options.merge(options)
      collector = options[:collector].split(':')

      @api_key     = api_key
      @host        = collector[0]
      @port        = (collector[1] || 8000).to_i
      @enabled     = options[:enabled]
      @test_mode   = options[:test_mode]
      @synchronous = options[:synchronous]
      @allow_reconnect = true
      @pid = Process.pid


      if @enabled
        @failures = 0
        @queue = Queue.new
        @sync_mutex = Mutex.new
        start_connection_worker
        setup_cleanup_at_exit
      end
    end

    # Store a gauge for a metric, optionally at a specific time.
    #
    #  agent.gauge('load', 1.23)
    def gauge(metric, value, time = Time.now)
      if valid?(metric, value, time) &&
          send_command("gauge", metric, value, time.to_i)
        value
      else
        nil
      end
    rescue Exception => e
      report_exception(e)
      nil
    end

    # Store the duration of a block in a metric. multiplier can be used
    # to scale the duration to desired unit or change the duration in
    # some meaningful way.
    #
    #  agent.time('response_time') do
    #    # potentially slow stuff
    #  end
    #
    #  agent.time('response_time_in_ms', 1000) do
    #    # potentially slow stuff
    #  end
    #
    #  ids = [1, 2, 3]
    #  agent.time('find_time_per_post', 1 / ids.size.to_f) do
    #    Post.find(ids)
    #  end
    def time(metric, multiplier = 1)
      start = Time.now
      begin
        result = yield
      ensure
        finish = Time.now
        duration = finish - start
        gauge(metric, duration * multiplier, start)
      end
      result
    end

    # Calls time and changes durations into milliseconds.
    def time_ms(metric, &block)
      time(metric, 1000, &block)
    end

    # Increment a metric, optionally more than one or at a specific time.
    #
    #  agent.increment('users')
    def increment(metric, value = 1, time = Time.now)
      if valid?(metric, value, time) &&
          send_command("increment", metric, value, time.to_i)
        value
      else
        nil
      end
    rescue Exception => e
      report_exception(e)
      nil
    end

    # Send a notice to the server (deploys, downtime, etc.)
    #
    #  agent.notice('A notice')
    def notice(note, time = Time.now, duration = 0)
      if valid_note?(note)
        send_command("notice", time.to_i, duration.to_i, note)
        note
      else
        nil
      end
    rescue Exception => e
      report_exception(e)
      nil
    end

    # Synchronously flush all pending metrics out to the server
    # By default will not try to reconnect to the server if a
    # connection failure happens during the flush, though you
    # may optionally override this behavior by passing true.
    #
    #  agent.flush
    def flush(allow_reconnect = false)
      queue_message('flush', {
        :synchronous => true,
        :allow_reconnect => allow_reconnect
      })
    end

    def enabled?
      @enabled
    end

    def connected?
      @socket && !@socket.closed?
    end

    def logger=(logger)
      @logger = logger
    end

    def logger
      @logger ||= self.class.logger
    end

    private

    def with_timeout(time, &block)
      tmr_klass = RUBY_VERSION < "1.9" ? SystemTimer : Timeout
      tmr_klass.timeout(time) { yield }
    end

    def valid_note?(note)
      note !~ /[\n\r]/
    end

    def valid?(metric, value, time)
      valid_metric = metric =~ /^([\d\w\-_]+\.)*[\d\w\-_]+$/i
      valid_value  = value.to_s =~ /^-?\d+(\.\d+)?(e-\d+)?$/

      return true if valid_metric && valid_value

      report_invalid_metric(metric) unless valid_metric
      report_invalid_value(metric, value) unless valid_value
      false
    end

    def report_invalid_metric(metric)
      increment "agent.invalid_metric"
      logger.warn "Invalid metric #{metric}"
    end

    def report_invalid_value(metric, value)
      increment "agent.invalid_value"
      logger.warn "Invalid value #{value.inspect} for #{metric}"
    end

    def report_exception(e)
      logger.error "Exception occurred: #{e.message}"
      logger.error e.backtrace.join("\n")
    end

    def send_command(cmd, *args)
      if enabled?
        if @pid != Process.pid
          logger.info "Detected fork"
          @pid = Process.pid
          @socket = nil
          @queue = Queue.new
          start_connection_worker
        end

        cmd = "%s %s\n" % [cmd, args.collect { |a| a.to_s }.join(" ")]
        if @queue.size < MAX_BUFFER
          logger.debug "Queueing: #{cmd.chomp}"
          queue_message(cmd, { :synchronous => @synchronous })
        else
          logger.warn "Dropping command, queue full(#{@queue.size}): #{cmd.chomp}"
          nil
        end
      end
    end

    def queue_message(message, options = {})
      if @enabled
        options ||= {}
        if options[:allow_reconnect].nil?
          options[:allow_reconnect] = @allow_reconnect
        end
        synchronous = options.delete(:synchronous)
        if synchronous
          options[:sync_resource] ||= ConditionVariable.new
          @queue << [message, options]
          @sync_mutex.synchronize {
            options[:sync_resource].wait(@sync_mutex)
          }
        else
          @queue << [message, options]
        end
      end
      message
    end

    def test_connection
      # FIXME: Test connection state hack
      begin
        @socket.read_nonblock(1) # TODO: put data back?
      rescue Errno::EAGAIN
        # noop
      end
    end

    def start_connection_worker
      if enabled?
        disconnect
        logger.info "Starting thread"
        @thread = Thread.new do
          run_worker_loop
        end
      end
    end

    def send_with_reply_timeout(message)
      @socket.puts message
      with_timeout(REPLY_TIMEOUT) do
        response = @socket.gets
        if response.to_s.chomp != "ok"
          raise "Bad Response #{response.inspect} to #{message.inspect}"
        end
      end
    end

    def run_worker_loop
      command_and_args = nil
      command_options = nil
      logger.info "connecting to collector"
      @socket = with_timeout(CONNECT_TIMEOUT) { TCPSocket.new(host, port) }
      logger.info "connected to collector at #{host}:#{port}"
      send_with_reply_timeout "hello version #{Instrumental::VERSION} test_mode #{@test_mode}"
      send_with_reply_timeout "authenticate #{@api_key}"
      @failures = 0
      loop do
        command_and_args, command_options = @queue.pop
        sync_resource = command_options && command_options[:sync_resource]
        test_connection
        case command_and_args
        when 'exit'
          logger.info "exiting, #{@queue.size} commands remain"
          return true
        when 'flush'
          release_resource = true
        else
          logger.debug "Sending: #{command_and_args.chomp}"
          @socket.puts command_and_args
        end
        command_and_args = nil
        command_options = nil
        if sync_resource
          @sync_mutex.synchronize do
            sync_resource.signal
          end
        end
      end
    rescue Exception => err
      logger.debug err.backtrace.join("\n")
      if @allow_reconnect == false ||
        (command_options && command_options[:allow_reconnect] == false)
        logger.error "Not trying to reconnect"
        return
      end
      if command_and_args
        logger.debug "requeueing: #{command_and_args}"
        @queue << command_and_args
      end
      disconnect
      @failures += 1
      delay = [(@failures - 1) ** BACKOFF, MAX_RECONNECT_DELAY].min
      logger.error "disconnected, #{@failures} failures in a row, reconnect in #{delay}..."
      sleep delay
      retry
    ensure
      disconnect
    end

    def setup_cleanup_at_exit
      at_exit do
        logger.info "Cleaning up agent, queue empty: #{@queue.empty?}, thread running: #{@thread.alive?}"
        @allow_reconnect = false
        logger.info "exit received, currently #{@queue.size} commands to be sent"
        queue_message('exit')
        begin
          with_timeout(EXIT_FLUSH_TIMEOUT) { @thread.join }
        rescue Timeout::Error
          if @queue.size > 0
            logger.error "Timed out working agent thread on exit, dropping #{@queue.size} metrics"
          else
            logger.error "Timed out Instrumental Agent, exiting"
          end
        end

      end
    end

    def disconnect
      if connected?
        logger.info "Disconnecting..."
        @socket.flush
        @socket.close
      end
      @socket = nil
    end

  end

end
