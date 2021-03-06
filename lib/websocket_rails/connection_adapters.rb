module WebsocketRails
  module ConnectionAdapters

    attr_reader :adapters
    module_function :adapters

    def self.register(adapter)
      @adapters ||= []
      @adapters.unshift adapter
    end

    def self.establish_connection(request, dispatcher)
      adapter = adapters.detect { |a| a.accepts?(request.env) } || raise(InvalidConnectionError)
      adapter.new request, dispatcher
    end

    class Base

      include Logging

      def self.accepts?(env)
        false
      end

      def self.inherited(adapter)
        ConnectionAdapters.register adapter
      end

      attr_reader :dispatcher, :queue, :env, :request, :data_store, :ip_address

      # The ConnectionManager will set the connection ID when the
      # connection is opened.
      attr_accessor :id

      def initialize(request, dispatcher)
        @env        = request.env.dup
        @request    = request
        @dispatcher = dispatcher
        @connected  = true
        @queue      = EventQueue.new
        @data_store = DataStore::Connection.new(self)
        @delegate   = WebsocketRails::DelegationController.new
        @delegate.instance_variable_set(:@_env, request.env)
        @delegate.instance_variable_set(:@_request, request)
        @ip_address = @env.to_s[/HTTP_X_FORWARDED_FOR.*?\,/][/[\d\.]+/]

        start_api_key_timer
        start_ping_timer
      end

      def on_open(data=nil)
        event = Event.new_on_open( self, data )
        dispatch event
      end

      def on_message(encoded_data)
        # it has to be a string at the moment, will have to reformat
        event = Event.new_on_message( self, encoded_data )
        dispatch event
      end

      def on_pong
        self.pong = true
      end

      def on_close(data=nil)
        @api_key_timer.try(:cancel)
        @ping_timer.try(:cancel)
        dispatch Event.new_on_close( self, data )
        self.close!
      end

      def on_error(data=nil)
        event = Event.new_on_error( self, data )
        dispatch event
        on_close event.data
      end

      def enqueue(event)
        @queue << event
      end

      def trigger(event)
        begin
          send event.data[:message]
        rescue
          logger.info "UNKNOWN ERROR OCCURED IN TRIGGER"
          # need to test the line below
          # send {type: "ERROR", content: "UNKNOWN ERROR OCCURED."}.to_json
        end
      end

      def flush
        message = []
        @queue.flush do |event|
          message << event.as_json
        end
        send message.to_json
      end

      def send_message(event_name, data = {}, options = {})
        options.merge! :user_id => user_identifier, :connection => self
        options[:data] = data

        event = Event.new(event_name, options)
        event.trigger
      end

      def send(message)
        raise NotImplementedError, "Override this method in the connection specific adapter class"
      end

      def rack_response
        [ -1, {}, [] ]
      end

      def controller_delegate
        @delegate
      end

      def connected?
        true & @connected
      end

      def inspect
        "#<Connection::#{id}>"
      end

      def to_s
        inspect
      end

      def user_connection?
        not user_identifier.nil?
      end

      def user
        return unless user_connection?
        controller_delegate.current_user
      end

      def user_identifier
        @user_identifier ||= begin
          identifier = WebsocketRails.config.user_identifier

          return unless current_user_responds_to?(identifier)

          controller_delegate.current_user.send(identifier)
         end
      end

      def ping_interval
        @ping_interval ||= WebsocketRails.config.default_ping_interval
      end

      def ping_interval=(interval)
        @ping_interval = interval.to_i
        @ping_timer.try(:cancel)
        start_ping_timer
      end

      def get_ip_address
        @ip_address
      end

      def authenticate_api_key
        self.api_key = true
      end

      private

      def dispatch(event)
        dispatcher.dispatch event
      end

      def connection_manager
        dispatcher.connection_manager
      end

      def close_connection
        @data_store.destroy!
        @ping_timer.try(:cancel)
        dispatcher.connection_manager.close_connection self
      end

      def current_user_responds_to?(identifier)
        controller_delegate                            &&
        controller_delegate.respond_to?(:current_user) &&
        controller_delegate.current_user               &&
        controller_delegate.current_user.respond_to?(identifier)
      end


      attr_accessor :pong, :api_key
      public :pong, :pong=, :api_key, :api_key=

      def start_api_key_timer
        @api_key = false
        @api_key_timer = EM::PeriodicTimer.new(5) do
          if api_key == false
            @api_key_timer.cancel
            on_error
          else
            @api_key_timer.cancel
          end
        end
      end

      def start_ping_timer
        @pong = true

        # Set negative interval to nil to deactivate periodic pings
        # ping_interval is new, I'll have to look and see how it used, maybe we can use it
        #if ping_interval > 0
          @ping_timer = EM::PeriodicTimer.new(30) do
            if pong == true
              self.pong = false
              ping = Event.new_on_ping self
              trigger ping
            else
              @ping_timer.cancel
              on_error
            end
          end
        #end
      end

    end
  end
end

