require "securerandom"

module Skylight
  # @api private
  class Middleware
    SKYLIGHT_REQUEST_ID = "skylight.request_id".freeze

    class BodyProxy
      def initialize(body, &block)
        @body = body
        @block = block
        @closed = false
      end

      def respond_to_missing?(name, include_all = false)
        return false if name.to_s =~ /^to_ary$/

        @body.respond_to?(name, include_all)
      end

      def close
        return if @closed

        @closed = true
        begin
          @body.close if @body.respond_to? :close
        ensure
          @block.call
        end
      end

      def closed?
        @closed
      end

      # N.B. This method is a special case to address the bug described by
      # https://github.com/rack/rack/issues/434.
      # We are applying this special case for #each only. Future bugs of this
      # class will be handled by requesting users to patch their ruby
      # implementation, to save adding too many methods in this class.
      def each(...)
        @body.each(...)
      end

      def method_missing(*args, &block)
        super if args.first.to_s =~ /^to_ary$/
        @body.__send__(*args, &block)
      end
    end

    def self.with_after_close(resp, debug_identifier: "unknown", &block)
      unless resp.respond_to?(:to_ary)
        if resp.respond_to?(:to_a)
          Skylight.warn(
            "Rack response from \"#{debug_identifier}\" cannot be implicitly converted to an array. " \
              "This is in violation of the Rack SPEC and will raise an error in future versions."
          )
          resp = resp.to_a
        else
          Skylight.error(
            "Rack response from \"#{debug_identifier}\" cannot be converted to an array. This is in " \
              "violation of the Rack SPEC and may cause problems with Skylight operation."
          )
          return resp
        end
      end

      status, headers, body = resp
      [status, headers, BodyProxy.new(body, &block)]
    end

    include Skylight::Util::Logging

    # For Util::Logging
    attr_reader :config

    def initialize(app, opts = {})
      @app = app
      @config = opts[:config]
    end

    def call(env)
      set_request_id(env)

      if Skylight.tracing?
        debug "Already instrumenting. Make sure the Skylight Rack Middleware hasn't been added more than once."
        return @app.call(env)
      end

      ignored_endpoints_regex_array = @config.instance_variable_get('@values')[:ignored_endpoints_regex] || []
      
      if env["REQUEST_METHOD"] == "HEAD" ||  ignored_endpoints_regex_array.any?{|regex| env['PATH_INFO'] =~ /#{regex}/}
        t { "middleware skipping" }
        @app.call(env)
      else
        begin
          t { "middleware beginning trace" }
          trace = Skylight.trace(endpoint_name(env), "app.rack.request", nil, meta: endpoint_meta(env), component: :web)
          t { "middleware began trace=#{trace ? trace.uuid : nil}" }

          resp = @app.call(env)

          trace ? Middleware.with_after_close(resp, debug_identifier: "Rack App: #{@app.class}") { trace.submit } : resp
        rescue Exception => e
          t { "middleware exception: #{e}\n#{e.backtrace.join("\n")}" }
          trace&.submit
          raise
        end
      end
    end

    private

    def log_context
      # Don't cache this, it will change
      { request_id: current_request_id, inst: Skylight.instrumenter&.uuid }
    end

    # Allow for overwriting
    def endpoint_name(_env)
      "Rack"
    end

    def endpoint_meta(_env)
      { source_location: Trace::SYNTHETIC }
    end

    # Request ID code based on ActionDispatch::RequestId
    def set_request_id(env)
      return if env[SKYLIGHT_REQUEST_ID]

      existing_request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
      self.current_request_id = env[SKYLIGHT_REQUEST_ID] = make_request_id(existing_request_id)
    end

    def make_request_id(request_id)
      request_id && !request_id.empty? ? request_id.gsub(/[^\w-]/, "".freeze)[0...255] : internal_request_id
    end

    def internal_request_id
      SecureRandom.uuid
    end

    def current_request_id
      Thread.current[SKYLIGHT_REQUEST_ID]
    end

    def current_request_id=(request_id)
      Thread.current[SKYLIGHT_REQUEST_ID] = request_id
    end
  end
end
