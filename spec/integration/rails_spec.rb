require "spec_helper"

enable = false
begin
  require "rails"
  require "action_controller/railtie"
  require "active_job/railtie"
  require "active_record"
  require "skylight/railtie"
  enable = true
rescue LoadError
  puts "[INFO] Skipping rails integration specs"
end

if enable
  describe "Rails integration" do
    # spec/support/http.rb uses these to locate the
    # expected agent reports.
    let(:report_environment) { "development" }
    let(:report_component) { "web" }

    def boot
      MyApp.config.exceptions_app = MyApp.routes
      MyApp.config.action_dispatch.rescue_responses.merge!(
        "ActiveRecord::RecordNotFound" => :not_found
      )

      MyApp.initialize!

      EngineNamespace::MyEngine.routes.draw do
        root to: ->(_env) { [204, {}, []] }
        get "/empty", to: ->(_env) { [204, {}, []] }, as: :empty
        get "/error_from_router", to: ->(_env) { raise "cannot even" }
        get "/error_from_controller", to: "application#error"
        get "/show", to: "application#show"
      end

      MyApp.routes.draw do
        resources :users do
          collection do
            get :failure
            get :handled_failure
            get :header
            get :status
            get :no_template
            get :too_many_spans
            get :throw_something
            get :inline_job
            get :send_png
            get :before_action_redirect
            get :action_redirect
            get :not_modified
            get :template_index
            get :muted_index
            get :normalizer_muted_index
            get :not_found
          end
        end
        get "/metal" => "metal#show"
        mount EngineNamespace::MyEngine => "/engine"
        get "/404" => "errors#not_found"
        get "/500" => "errors#internal"
      end
    end

    around { |ex| set_agent_env(&ex) }

    let(:error_segment) { "<sk-segment>error</sk-segment>" }

    before :each do
      stub_const("ControllerError", Class.new(StandardError))
      stub_const("MiddlewareError", Class.new(StandardError))

      stub_const(
        "MyApplicationJob",
        Class.new(ActiveJob::Base) do
          def perform(*)
            true
          end
        end
      )

      stub_const(
        "SkTestMiddleware",
        Struct.new(:app) do
          def call(env)
            app.call(env)
          end

          private

          def query_parameters(env)
            ActionDispatch::Request.new(env).query_parameters
          end
        end
      )

      @custom_middleware_line = __LINE__ + 4
      stub_const(
        "CustomMiddleware",
        Class.new(SkTestMiddleware) do
          def call(env)
            return 200, {}, ["CustomMiddleware"] if env["PATH_INFO"] == "/middleware"

            super
          end
        end
      )

      stub_const(
        "NonClosingMiddleware",
        Class.new(SkTestMiddleware) do
          def call(env)
            super.tap do
              # NOTE: We are intentionally throwing away the response without calling close
              # This is to emulate a non-conforming Middleware
              return 200, {}, ["NonClosing"] if env["PATH_INFO"] == "/non-closing"
            end
          end
        end
      )

      stub_const(
        "NonArrayMiddleware",
        Class.new(SkTestMiddleware) do
          def call(env)
            return Rack::Response.new(["NonArray"]) if env["PATH_INFO"] == "/non-array"

            super
          end
        end
      )

      stub_const(
        "InvalidMiddleware",
        Class.new(SkTestMiddleware) do
          def call(env)
            return "InvalidMiddlewareResponse" if env["PATH_INFO"] == "/invalid"

            super
          end
        end
      )

      stub_const(
        "AssertionHook",
        Class.new(SkTestMiddleware) do
          def call(env)
            super
          ensure
            assertion_hook
          end

          private

          def assertion_hook
            # override in rspec
          end
        end
      )

      # These need to be distinguished by class name in order to use
      # the 'any_instance_of' matchers. It's otherwise too difficult to
      # get compiled middleware stack instances.
      stub_const("AssertionHookA", Class.new(AssertionHook))
      stub_const("AssertionHookB", Class.new(AssertionHook))

      stub_const(
        "RescuingMiddleware",
        Class.new(SkTestMiddleware) do
          def call(env)
            super
          rescue MiddlewareError => e
            # start a new span here; helps ensure traces/instrumenters are unmuted
            Skylight.instrument("post-rescue") { SpecHelper.clock.skip 1 }
            [500, {}, ["error=#{e.class.inspect} msg=#{e.to_s.inspect}"]]
          end
        end
      )

      stub_const(
        "CatchingMiddleware",
        Class.new(SkTestMiddleware) do
          def self.thrown_response
            [:coconut, [401, {}, ["I can't do that, Dave"]]]
          end

          def call(env)
            catch(thrown_response[0]) { super }.tap do |r|
              # start a new span here; helps ensure traces/instrumenters are unmuted
              Skylight.instrument("post-catch") { SpecHelper.clock.skip 1 } if r == thrown_response[1]
            end
          end

          def thrown_response
            self.class.thrown_response
          end
        end
      )

      stub_const(
        "MonkeyInTheMiddleware",
        Class.new(SkTestMiddleware) do
          def call(env)
            if should_mute?(env)
              Skylight.instrument(title: "banana", meta: { mute_children: true }) { super }
            else
              super
            end
          end

          private

          def should_mute?(env)
            query_parameters(env)[:mute] == "true"
          end
        end
      )

      stub_const(
        "ThrowingMiddleware",
        Class.new(SkTestMiddleware) do
          def call(env)
            throw(*CatchingMiddleware.thrown_response) if should_throw?(env)
            raise MiddlewareError, "I can't do that, Dave" if should_raise?(env)

            super
          end

          private

          def should_throw?(env)
            query_parameters(env)[:middleware_throws] == "true"
          end

          def should_raise?(env)
            query_parameters(env)[:middleware_raises] == "true"
          end
        end
      )

      stub_const("EngineNamespace", Module.new)

      # stree-ignore
      begin # rubocop:disable Style/RedundantBegin
        EngineNamespace.module_eval <<~RUBY, __FILE__, __LINE__ + 1
          class MyEngine < ::Rails::Engine
            isolate_namespace EngineNamespace
          end

          class ApplicationController < ActionController::Base
            def error
              raise ActiveRecord::RecordNotFound
            end

            def show
              render json: {}
            end
          end
        RUBY
      end

      stub_const(
        "SkMutingNormalizer",
        Class.new(Skylight::Normalizers::Normalizer) do
          register "mute.skylight"

          def normalize(_trace, _name, _payload)
            ["app.mute", nil, nil, { mute_children: true }]
          end

          def normalize_after(trace, _span, _name, _payload)
            trace.endpoint = "set-by-muted-normalizer"
          end
        end
      )

      # stub_const doesn't work well for this. We do manual cleanup afterwards.
      class ::MyApp < Rails::Application # rubocop:disable Lint/ConstantDefinitionInBlock
        PNG = [
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
          0,
          0,
          0,
          13,
          73,
          72,
          68,
          82,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          1,
          8,
          0,
          0,
          0,
          0,
          58,
          126,
          155,
          85,
          0,
          0,
          0,
          10,
          73,
          68,
          65,
          84,
          120,
          156,
          99,
          250,
          15,
          0,
          1,
          5,
          1,
          2,
          207,
          160,
          46,
          205,
          0,
          0,
          0,
          0,
          73,
          69,
          78,
          68,
          174,
          66,
          96,
          130
        ].pack("C*")

        config.secret_key_base = "095f674153982a9ce59914b561f4522a"

        config.active_support.deprecation = :stderr

        config.logger = Logger.new($stdout)
        config.log_level = ENV["DEBUG"] ? :debug : :unknown
        config.logger.progname = "Rails"

        config.eager_load = false

        # Log request ids
        config.log_tags = Rails.version =~ /^4\./ ? [:uuid] : [:request_id]

        if defined?(ActionView::Railtie::NULL_OPTION)
          config.action_view.finalize_compiled_template_methods = ActionView::Railtie::NULL_OPTION
        end

        # Rails Edge: https://github.com/rails/rails/pull/33145/files
        if defined?(config.hosts)
          # Allow all hosts: https://github.com/rails/rails/pull/33145/files
          config.hosts << proc { true }
        end

        # This class has no name
        ANONYMOUS_MIDDLEWARE_LINE = __LINE__ + 7
        config.middleware.use(
          Class.new do
            def initialize(app) # rubocop:disable Lint/MissingSuper
              @app = app
            end

            def call(env)
              return 200, {}, ["Anonymous"] if env["PATH_INFO"] == "/anonymous"

              @app.call(env)
            end
          end
        )

        config.middleware.use NonClosingMiddleware
        config.middleware.use NonArrayMiddleware
        config.middleware.use InvalidMiddleware
        config.middleware.use CustomMiddleware
        config.middleware.use AssertionHookA
        config.middleware.use RescuingMiddleware
        config.middleware.use CatchingMiddleware
        config.middleware.use MonkeyInTheMiddleware
        config.middleware.use AssertionHookB
        config.middleware.use ThrowingMiddleware

        config.many = 10
        config.very_many = 300
        config.active_job.queue_adapter = (Rails::VERSION::MAJOR >= 5 ? :async : :inline)
      end

      class User < ActiveRecord::Base # rubocop:disable Lint/ConstantDefinitionInBlock
      end

      # We include instrument_method in multiple places to ensure
      # that all of them work.

      # It's hard for us to match the naming for this if we use stub_const. We manually remove later.
      class ::UsersController < ActionController::Base # rubocop:disable Lint/ConstantDefinitionInBlock
        include Skylight::Helpers

        if respond_to?(:before_action)
          before_action :authorized?
          before_action :set_variant
        else
          before_filter :authorized?
          before_filter :set_variant
        end

        rescue_from "ControllerError" do |exception|
          render json: { error: exception.message }, status: 418
        end

        const_set(:INDEX_LINE, __LINE__ + 1)
        def index
          return index_with_db if params[:active_record]

          index_inner
        end
        instrument_method :index

        INDEX_DB_LINE = __LINE__ + 2
        instrument_method
        def index_with_db
          users = User.where(username: "foo").limit(10).to_a

          index_inner do
            # purposefully repeat the same operation at a different location
            users = User.where(username: "foo").limit(10).to_a
          end
        end

        def index_inner
          Skylight.instrument category: "app.inside" do
            yield if block_given?

            if Rails.version =~ /^4\./
              render text: "Hello"
            else
              render plain: "Hello"
            end
            Skylight.instrument category: "app.zomg" do
              # nothing
            end
          end
        end

        instrument_method
        def show
          respond_to do |format|
            format.json do |json|
              json.tablet { render json: { hola_tablet: params[:id] } }
              json.none { render json: { hola: params[:id] } }
            end
            format.html { render plain: "Hola: #{params[:id]}" }
          end
        end

        def template_index
          @hello = "hi"
          render "index", layout: "app"
        end

        instrument_method title: "muted-index"
        def muted_index
          Skylight.mute { muted_index_inner }
        end

        instrument_method title: "normalizer-muted-index"
        def normalizer_muted_index
          ActiveSupport::Notifications.instrument("mute.skylight") { muted_index_inner }
        end

        def muted_index_inner
          index
          throw_something if params[:throw_something]
          raise MiddlewareError if params[:raise_error]
        end

        def inline_job
          MyApplicationJob.perform_now
          render json: {}
        end

        def failure
          raise "Fail!"
        end

        def handled_failure
          raise ControllerError, "Handled!"
        end

        def header
          Skylight.instrument category: "app.zomg" do
            head 200
          end
        end

        def status
          s = params[:status] || 200
          if Rails.version =~ /^4\./
            render text: s, status: s
          else
            render plain: s, status: s
          end
        end

        def not_found
          raise ActiveRecord::RecordNotFound
        end

        def no_template
          # This action has no template to auto-render
        end

        def too_many_spans
          # Max is 2048
          Rails.application.config.many.times do
            Skylight.instrument category: "app.zomg.level-1" do
              Skylight.instrument category: "app.zomg.should-prune-below-here" do
                Rails.application.config.very_many.times do
                  Skylight.instrument category: "app.zomg.level-2" do
                    # nothing
                  end
                end
              end
            end
          end

          if Rails.version =~ /^4\./
            render text: "There's too many of them!"
          else
            render plain: "There's too many of them!"
          end
        end

        def throw_something
          throw(*CatchingMiddleware.thrown_response)
        end

        def send_png
          send_data ::MyApp::PNG, content_type: "image/png", status: :ok
        end

        def not_modified
          head :not_modified
        end

        before_action only: :before_action_redirect do
          redirect_to "/"
        end

        def before_action_redirect
        end

        def action_redirect
          redirect_to "/"
        end

        private

        const_set(:AUTHORIZED_LINE, __LINE__ + 1)
        def authorized?
          true
        end

        # It's important for us to test a method ending in a special char
        instrument_method :authorized?, title: "Check authorization"

        def set_variant
          request.variant = :tablet if params[:tablet]
        end

        protected

        # For checking visibilty only
        instrument_method
        def unused
        end
      end

      # It's hard for us to match the naming for this if we use stub_const. We manually remove later.
      # class ::UsersController < ActionController::Base
      stub_const(
        "ErrorsController",
        Class.new(ActionController::Base) do
          def not_found
            render(status: 404, plain: "failsafe response: resource not found")
          end

          def internal
            exception = request.env["action_dispatch.exception"]
            render(status: 500, plain: "failsafe response: #{exception.inspect}")
          end
        end
      )

      stub_const(
        "MetalController",
        Class.new(ActionController::Metal) do
          include ActionController::Instrumentation

          def show
            render(status: 200, text: "Zomg!")
          end

          def render(options = {})
            self.status = options[:status] || 200
            self.content_type = options[:content_type] || "text/html; charset=utf-8"
            headers["Content-Length"] = options[:text].bytesize.to_s
            self.response_body = options[:text]
          end
        end
      )
    end

    after :each do
      MyApp.config.skylight.middleware_position = 0

      Skylight.stop!

      # Clean slate
      # It's really too bad we can't run RSpec tests in a fork
      Object.send(:remove_const, :MyApp)
      Object.send(:remove_const, :UsersController)
      Object.send(:remove_const, :User)
      Rails::Railtie::Configuration.class_variable_set(:@@app_middleware, nil) # rubocop:disable Style/ClassVars
      Rails.application = nil

      # For Rails 7, which freezes these in an initializer.
      # Can't start a new instance of the application when these are frozen.
      ActiveSupport::Dependencies.autoload_paths = []
      ActiveSupport::Dependencies.autoload_once_paths = []
    end

    let(:router_name) { "ActionDispatch::Routing::RouteSet" }

    shared_examples "with agent [minimal]" do
      it "successfully calls into rails" do
        res = call MyApp, env("/users")
        expect(res).to eq(["Hello"])

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]

        segment = Rails.version =~ /^4\./ ? "html" : "text"
        expect(endpoint.name).to eq("UsersController#index<sk-segment>#{segment}</sk-segment>")
        expect(endpoint.traces.count).to eq(1)
        trace = endpoint.traces[0]

        app_spans = trace.filter_spans.map { |s| [s.event.category, s.event.title] }.select { |s| s[0] =~ /^app./ }
        expect(app_spans).to eq(
          [
            ["app.rack.request", nil],
            %w[app.controller.request UsersController#index],
            ["app.method", "Check authorization"],
            %w[app.method UsersController#index],
            ["app.inside", nil],
            ["app.zomg", nil]
          ]
        )
      end
    end

    shared_examples "with agent" do
      it_behaves_like "with agent [minimal]"

      context "configuration" do
        it "sets log file" do
          expect(Skylight.instrumenter.config["log_file"]).to eq(MyApp.root.join("log/skylight.log").to_s)
        end

        it "sets native log file" do
          expect(Skylight.instrumenter.config.native_log_file).to eq(MyApp.root.join("log/skylight.native.log").to_s)
        end

        context "on heroku" do
          def pre_boot
            ENV["SKYLIGHT_HEROKU_DYNO_INFO_PATH"] = File.expand_path("../support/heroku_dyno_info_sample", __dir__)
          end

          it "recognizes heroku" do
            expect(Skylight.instrumenter.config).to be_on_heroku
          end

          it "leaves log file as STDOUT" do
            expect(Skylight.instrumenter.config["log_file"]).to eq("-")
          end

          it "sets native log file as STDOUT" do
            expect(Skylight.instrumenter.config.native_log_file).to eq("-")
          end
        end
      end

      it "successfully instruments middleware", :middleware_probe do
        # Change root so that we can properly test sanitization
        use_spec_root!

        call MyApp, env("/users")
        server.wait resource: "/report"

        report = server.reports.first

        source_locations = report.source_locations
        trace = report.dig(:endpoints, 0, :traces, 0)

        app_and_rack_spans = trace.spans.select { |s| s.event.category =~ /^(app|rack)./ }

        # We know the first one
        expect(app_and_rack_spans[0]).to match(a_span_including(event: an_exact_event(category: "app.rack.request")))

        router_index = app_and_rack_spans.index { |span| span.event.title == "ActionDispatch::Routing::RouteSet" }

        # We should have at least 2 middlewares in addition
        # to the root request span, but in reality should be a lot more
        expect(router_index).to be > 3

        source_file = Pathname.new(__FILE__).relative_path_from(spec_root).to_s
        source_file_index = source_locations.index(source_file)

        action_pack_source_location_index = source_locations.index("actionpack")

        middleware_spans = app_and_rack_spans[0...router_index]

        # These ones should be in all versions
        expect(middleware_spans).to include(
          a_span_including(
            event: an_exact_event(category: "rack.middleware", title: "Anonymous Middleware"),
            annotations:
              include(an_annotation(:SourceLocation, "#{source_file_index}:#{MyApp::ANONYMOUS_MIDDLEWARE_LINE}"))
          )
        )

        expect(middleware_spans).to include(
          a_span_including(
            event: an_exact_event(category: "rack.middleware", title: "CustomMiddleware"),
            annotations: include(an_annotation(:SourceLocation, "#{source_file_index}:#{@custom_middleware_line}"))
          )
        )

        # Check the rest
        post_middleware_spans = app_and_rack_spans[router_index..]
        expect(post_middleware_spans).to match(
          [
            a_span_including(
              event: an_exact_event(category: "rack.app", title: router_name),
              annotations: include(an_annotation(:SourceLocation, action_pack_source_location_index.to_s))
            ),
            a_span_including(
              event: an_exact_event(category: "app.controller.request", title: "UsersController#index"),
              annotations:
                include(an_annotation(:SourceLocation, "#{source_file_index}:#{UsersController::INDEX_LINE}"))
            ),
            a_span_including(
              event: an_exact_event(category: "app.method", title: "Check authorization"),
              annotations:
                include(an_annotation(:SourceLocation, "#{source_file_index}:#{UsersController::AUTHORIZED_LINE}"))
            ),
            a_span_including(
              event: an_exact_event(category: "app.method", title: "UsersController#index"),
              annotations:
                include(an_annotation(:SourceLocation, "#{source_file_index}:#{UsersController::INDEX_LINE}"))
            ),
            a_span_including(event: an_exact_event(category: "app.inside")),
            a_span_including(event: an_exact_event(category: "app.zomg"))
          ]
        )
      end

      context "with template rendering" do
        def pre_boot
          super
          FileUtils.mkdir_p(expand_path("users"))
          FileUtils.mkdir_p(expand_path("layouts"))
          File.open(expand_path("users/index.html.erb"), "w") { |f| f << "<%= @hello %>" }
          File.open(expand_path("layouts/app.html.erb"), "w") { |f| f << "<h1>App.</h1><%= yield %>" }
        end

        def expand_path(relative_path)
          Rails.root.join("app/views", relative_path)
        end

        it "includes relative paths to the ActionView templates" do
          if defined?(ActionView::CacheExpiry)
            allow_any_instance_of(ActionView::CacheExpiry).to receive(:dirs_to_watch) { [] }
          end

          status, _headers, _body = call_full MyApp, env("/users/template_index.html")

          expect(status).to eq(200)

          server.wait resource: "/report"

          batch = server.reports[0]
          expect(batch).not_to be nil
          expect(batch.endpoints.count).to eq(1)
          endpoint = batch.endpoints[0]

          expect(endpoint.name).to eq("UsersController#template_index<sk-segment>html</sk-segment>")

          *_spans, layout_span, template_span =
            endpoint.traces[0].filter_spans.map { |span| [span.event.category, span.event.title] }

          expect(template_span).to eq(%w[view.render.template users/index.html.erb])

          if ActionView.gem_version >= Gem::Version.new("6.1.0.alpha")
            expect(layout_span).to eq(%w[view.render.layout layouts/app.html.erb])
          else
            expect(layout_span).to eq(%w[view.render.template layouts/app.html.erb])
          end
        end
      end

      it "successfully names requests handled by middleware", :middleware_probe do
        res = call MyApp, env("/middleware")
        expect(res).to eq(["CustomMiddleware"])

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]

        expect(endpoint.name).to eq("CustomMiddleware")
      end

      it "successfully names requests handled by anonymous middleware", :middleware_probe do
        res = call MyApp, env("/anonymous")
        expect(res).to eq(["Anonymous"])

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]

        expect(endpoint.name).to eq("Anonymous Middleware")
      end

      context "with middleware_position" do
        def pre_boot
          MyApp.config.skylight.middleware_position = { after: CustomMiddleware }
        end

        it "does not instrument middleware if Skylight position is after", :middleware_probe do
          call MyApp, env("/users")
          server.wait resource: "/report"

          trace = server.reports.dig(0, :endpoints, 0, :traces, 0)

          titles = trace.filter_spans.map { |s| s.event.title }

          # If Skylight runs after CustomMiddleware, we shouldn't see it
          expect(titles).not_to include("CustomMiddleware")
        end
      end

      context "middleware that does not conform to Rack SPEC" do
        after :each do
          Skylight::Probes::Middleware::Probe.enable!
        end

        # The middleware probe is not installed when this built-in instrumenter exists.
        if defined?(ActionDispatch::MiddlewareStack::InstrumentationProxy)
          it "reports normally" do
            ENV["SKYLIGHT_RAISE_ON_ERROR"] = nil
            call MyApp, env("/non-closing")

            server.wait resource: "/report"
            trace = server.reports.dig(0, :endpoints, 0, :traces, 0)
            titles = trace.filter_spans.map { |s| s.event.title }.reverse

            expected_titles = %w[
              Anonymous\ Middleware
              NonClosingMiddleware
              NonArrayMiddleware
              InvalidMiddleware
              CustomMiddleware
              AssertionHookA
              RescuingMiddleware
              CatchingMiddleware
              MonkeyInTheMiddleware
              AssertionHookB
              ThrowingMiddleware
              ActionDispatch::Routing::RouteSet
            ]
            expect(titles.take(12).reverse).to eq(expected_titles)
          end
        else
          it "doesn't report middleware that does not close body", :middleware_probe do
            ENV["SKYLIGHT_RAISE_ON_ERROR"] = nil

            expect_any_instance_of(Skylight::Instrumenter).not_to receive(:process)

            call MyApp, env("/non-closing")
          end

          it "disables probe when middleware does not close body", :middleware_probe do
            ENV["SKYLIGHT_RAISE_ON_ERROR"] = nil

            call MyApp, env("/non-closing")

            expect(Skylight::Probes::Middleware::Probe).to be_disabled
          end
        end

        it "handles middleware that returns a non-array that is coercable", :middleware_probe do
          ENV["SKYLIGHT_RAISE_ON_ERROR"] = nil

          call MyApp, env("/non-array")
          server.wait resource: "/report"

          trace = server.reports[0].endpoints[0].traces[0]
          titles = trace.filter_spans.map { |s| s.event.title }

          expect(titles).to include("NonArrayMiddleware")
        end
      end

      context "muted instrumentation" do
        let(:segment) { Rails.version =~ /^4\./ ? "html" : "text" }
        it "does not record instrumentation wrapped in a mute block" do
          call MyApp, env("/users/muted_index")
          server.wait resource: "/report"

          endpoint = server.reports.dig(0, :endpoints, 0)
          expect(endpoint.name).to eq("UsersController#muted_index<sk-segment>#{segment}</sk-segment>")

          trace = endpoint.dig(:traces, 0)
          spans = trace.filter_spans.map { |s| [s.event.category, s.event.title] }.select { |s| s[0] =~ /^app./ }

          expect(spans).to eq(
            [
              ["app.rack.request", nil],
              %w[app.controller.request UsersController#muted_index],
              ["app.method", "Check authorization"],
              %w[app.method muted-index]
            ]
          )
        end

        it "handles thrown messages" do
          resp = call MyApp, env("/users/muted_index?throw_something=true")
          server.wait resource: "/report"

          expect_caught_response(resp)

          endpoint = server.reports.dig(0, :endpoints, 0)
          expect(endpoint.name).to eq("UsersController#muted_index<sk-segment>#{segment}</sk-segment>")

          trace = endpoint.dig(:traces, 0)

          spans = trace.filter_spans.map { |s| [s.event.category, s.event.title] }.select { |s| s[0] =~ /^app./ }

          expect(spans).to eq(
            [
              ["app.rack.request", nil],
              %w[app.controller.request UsersController#muted_index],
              ["app.method", "Check authorization"],
              %w[app.method muted-index],
              %w[app.block post-catch]
            ]
          )
        end

        it "handles errors" do
          call MyApp, env("/users/muted_index?raise_error=true")
          server.wait resource: "/report"

          endpoint = server.reports.dig(0, :endpoints, 0)
          expect(endpoint.name).to eq("UsersController#muted_index<sk-segment>error</sk-segment>")

          trace = endpoint.dig(:traces, 0)
          spans = trace.filter_spans.map { |s| [s.event.category, s.event.title] }.select { |s| s[0] =~ /^app./ }

          expect(spans).to eq(
            [
              ["app.rack.request", nil],
              %w[app.controller.request UsersController#muted_index],
              ["app.method", "Check authorization"],
              %w[app.method muted-index],
              %w[app.block post-rescue]
            ]
          )
        end
      end

      context "muted normalizer", mute: true do
        let(:segment) { Rails.version =~ /^4\./ ? "html" : "text" }

        it "does not record instrumentation wrapped in a mute block" do
          call MyApp, env("/users/normalizer_muted_index")
          server.wait resource: "/report"

          endpoint = server.reports.dig(0, :endpoints, 0)
          expect(endpoint.name).to eq("set-by-muted-normalizer<sk-segment>#{segment}</sk-segment>")

          trace = endpoint.dig(:traces, 0)

          spans = trace.filter_spans.map { |s| [s.event.category, s.event.title] }.select { |s| s[0] =~ /^app./ }
          expect(spans).to eq(
            [
              ["app.rack.request", nil],
              %w[app.controller.request UsersController#normalizer_muted_index],
              ["app.method", "Check authorization"],
              %w[app.method normalizer-muted-index],
              ["app.mute", nil]
            ]
          )
        end

        it "handles thrown messages" do
          resp = call MyApp, env("/users/normalizer_muted_index?throw_something=true")
          server.wait resource: "/report"

          expect_caught_response(resp)

          endpoint = server.reports.dig(0, :endpoints, 0)
          expect(endpoint.name).to eq("set-by-muted-normalizer<sk-segment>#{segment}</sk-segment>")

          trace = endpoint.dig(:traces, 0)
          spans = trace.filter_spans.map { |s| [s.event.category, s.event.title] }.select { |s| s[0] =~ /^app./ }

          expect(spans).to eq(
            [
              ["app.rack.request", nil],
              %w[app.controller.request UsersController#normalizer_muted_index],
              ["app.method", "Check authorization"],
              %w[app.method normalizer-muted-index],
              ["app.mute", nil],
              %w[app.block post-catch]
            ]
          )
        end

        it "handles errors" do
          call MyApp, env("/users/normalizer_muted_index?raise_error=true")
          server.wait resource: "/report"

          endpoint = server.reports.dig(0, :endpoints, 0)
          expect(endpoint.name).to eq("set-by-muted-normalizer<sk-segment>error</sk-segment>")

          trace = endpoint.dig(:traces, 0)
          spans = trace.filter_spans.map { |s| [s.event.category, s.event.title] }.select { |s| s[0] =~ /^app./ }

          expect(spans).to eq(
            [
              ["app.rack.request", nil],
              %w[app.controller.request UsersController#normalizer_muted_index],
              ["app.method", "Check authorization"],
              %w[app.method normalizer-muted-index],
              ["app.mute", nil],
              %w[app.block post-rescue]
            ]
          )
        end
      end

      context "middleware that jumps the stack" do
        it "closes jumped spans" do
          resp = call(MyApp, env("/foo?middleware_throws=true"))
          server.wait(resource: "/report")

          expect_caught_response(resp)

          batch = server.reports[0]
          expect(batch).to be_present
          endpoint = batch.endpoints[0]
          expect(endpoint.name).to eq("ThrowingMiddleware")
          trace = endpoint.traces[0]

          reverse_spans = trace.filter_spans.reverse_each.map { |span| span.event.title }
          post_catch, throwing, _hook_b, middle, catcher = reverse_spans

          expect(post_catch).to eq("post-catch")
          expect(throwing).to eq("ThrowingMiddleware")
          expect(middle).to eq("MonkeyInTheMiddleware")
          expect(catcher).to eq("CatchingMiddleware")
        end

        it "closes spans over rescue blocks" do
          resp = call(MyApp, env("/foo?middleware_raises=true"))
          server.wait(resource: "/report")

          expect(resp[0]).to start_with("error=MiddlewareError")

          batch = server.reports[0]
          expect(batch).to be_present
          endpoint = batch.endpoints[0]
          expect(endpoint.name).to eq("ThrowingMiddleware")
          trace = endpoint.traces[0]

          reverse_spans = trace.filter_spans.reverse_each.map { |span| span.event.title }
          post_rescue, last, _hook_b, middle, catcher, rescuer = reverse_spans

          expect(post_rescue).to eq("post-rescue")
          expect(last).to eq("ThrowingMiddleware")
          expect(middle).to eq("MonkeyInTheMiddleware")
          expect(catcher).to eq("CatchingMiddleware")
          expect(rescuer).to eq("RescuingMiddleware")
        end

        it "closes spans jumped in the controller" do
          resp = call(MyApp, env("/users/throw_something"))
          server.wait(resource: "/report")

          expect_caught_response(resp)

          batch = server.reports[0]
          expect(batch).to be_present
          endpoint = batch.endpoints[0]
          expect(endpoint.name).to eq("UsersController#throw_something")
          trace = endpoint.traces[0]

          reverse_spans = trace.filter_spans.reverse_each.map { |span| [span.event.category, span.event.title] }

          # it closes all spans between the throw and the catch
          expect(reverse_spans.take(8)).to eq(
            [
              %w[app.block post-catch],
              ["app.method", "Check authorization"],
              %w[app.controller.request UsersController#throw_something],
              ["rack.app", router_name],
              %w[rack.middleware ThrowingMiddleware],
              %w[rack.middleware AssertionHookB],
              %w[rack.middleware MonkeyInTheMiddleware],
              %w[rack.middleware CatchingMiddleware]
            ]
          )
        end

        it "unmutes instrumentation even when the disabled span was deferred" do
          expect_any_instance_of(AssertionHookA).to receive(:assertion_hook) do
            expect(Skylight.trace).not_to be_tracing_muted
          end

          expect_any_instance_of(AssertionHookB).to receive(:assertion_hook) do
            expect(Skylight.trace).to be_tracing_muted
          end

          resp = call(MyApp, env("/users?mute=true&middleware_throws=true"))
          server.wait(resource: "/report")

          expect_caught_response(resp)

          batch = server.reports[0]
          expect(batch).to be_present
          endpoint = batch.endpoints[0]

          # This is the last endpoint name that was assigned before instrumentation was disabled
          expect(endpoint.name).to eq("MonkeyInTheMiddleware")
          trace = endpoint.traces[0]

          reverse_spans = trace.filter_spans.reverse_each.map { |span| [span.event.category, span.event.title] }

          # it closes all spans between the throw and the catch
          expect(reverse_spans.take(4)).to eq(
            [
              %w[app.block post-catch],
              %w[app.block banana],
              %w[rack.middleware MonkeyInTheMiddleware],
              %w[rack.middleware CatchingMiddleware]
            ]
          )
        end
      end

      context "with too many spans" do
        context "with reporting turned on" do
          def pre_boot
            ENV["SKYLIGHT_REPORT_MAX_SPANS_EXCEEDED"] = "true"
            ENV["SKYLIGHT_PRUNE_LARGE_TRACES"] = "false"
          end

          it "handles too many spans" do
            segment = Rails.version =~ /^4\./ ? "html" : "text"

            expect_any_instance_of(Skylight::Trace).to receive(:error).with(
              /\[E%04d\].+endpoint=%s/,
              3,
              "UsersController#too_many_spans"
            )

            call MyApp, env("/users/too_many_spans")

            server.wait resource: "/report"

            batch = server.reports[0]
            expect(batch).not_to be nil
            expect(batch.endpoints.count).to eq(1)
            endpoint = batch.endpoints[0]

            expect(endpoint.name).to eq("UsersController#too_many_spans<sk-segment>#{segment}</sk-segment>")
            expect(endpoint.traces.count).to eq(1)
            trace = endpoint.traces[0]

            spans = trace.filter_spans.map { |s| [s.event.category, s.event.title] }

            expect(spans).to eq([["app.rack.request", nil], ["agent.error.E0003", nil]])
          end
        end

        context "without reporting" do
          def pre_boot
            ENV["SKYLIGHT_PRUNE_LARGE_TRACES"] = "false"
          end

          it "handles too many spans" do
            ENV["SKYLIGHT_RAISE_ON_ERROR"] = nil

            expect_any_instance_of(Skylight::Instrumenter).not_to receive(:process)

            call MyApp, env("/users/too_many_spans")
          end
        end

        context "with pruning" do
          def pre_boot
            ENV["SKYLIGHT_PRUNE_LARGE_TRACES"] = "true"
          end

          it "handles too many spans" do
            call MyApp, env("/users/too_many_spans")
            server.wait resource: "/report"

            batch = server.reports[0]
            spans = batch.endpoints[0].traces[0].spans

            categories = spans.each_with_object(Hash.new(0)) { |span, counts| counts[span.event.category] += 1 }

            expect(categories["app.zomg.level-1"]).to eq(MyApp.config.many)

            # The spans whose children were pruned should all now contain an error child
            expect(categories["app.zomg.should-prune-below-here"]).to eq(MyApp.config.many)
            expect(categories["agent.error.E0003"]).to eq(MyApp.config.many)

            # These have been discarded entirely
            expect(categories["app.zomg.level-2"]).to eq(0)
          end
        end
      end

      it "sets correct segment" do
        res = call MyApp, env("/users/1.json")
        expect(res).to eq([{ hola: "1" }.to_json])

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#show<sk-segment>json</sk-segment>")
      end

      it "sets correct segment for router-handled requests" do
        res = call MyApp, env("/engine/empty")
        expect(res).to eq([])

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).to_not be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq(router_name)
      end

      it "sets correct segment for an engine" do
        res = call MyApp, env("/engine/error_from_router")
        expect(res).to eq(["failsafe response: #<RuntimeError: cannot even>"])
        server.wait(resource: "/report")
        endpoint = server.reports[0].endpoints[0]
        expect(endpoint.name).to eq("#{router_name}#{error_segment}")
        trace = endpoint.traces.first
        spans = trace.filter_spans

        # Should include the routers from both the main app and the engine
        expect(spans.last(5).map { |s| s.event.title }).to eq(
          [
            router_name, # main app
            router_name, # engine router
            router_name, # for exceptions app
            "ErrorsController#internal",
            "text template"
          ]
        )
      end

      it "forwards exceptions in the engine to the main app" do
        call MyApp, env("/engine/error_from_controller")

        server.wait(resource: "/report")
        endpoint = server.reports[0].endpoints[0]
        endpoint_name = "EngineNamespace::ApplicationController#error"
        expect(endpoint.name).to eq("#{endpoint_name}#{error_segment}")
        trace = endpoint.traces.first
        spans = trace.filter_spans.last(6)

        # Should include the routers from both the main app and the engine
        expect(spans.map { |s| s.event.title }).to eq(
          [
            router_name, # main app
            router_name, # engine router
            endpoint_name,
            router_name, # for exceptions app
            "ErrorsController#not_found",
            "text template"
          ]
        )
      end

      it "handles routing errors" do
        expect { call MyApp, env("/engine/foo/bar/bin") }.not_to raise_error

        server.wait(resource: "/report")
        endpoint = server.reports[0].endpoints[0]
        expect(endpoint.name).to eq("#{router_name}#{error_segment}")
        trace = endpoint.traces.first
        spans = trace.filter_spans.last(5)

        # Should include the routers from both the main app and the engine
        expect(spans.map { |s| s.event.title }).to eq(
          [
            router_name, # main app
            router_name, # engine router
            router_name, # for exceptions app
            "ErrorsController#not_found",
            "text template"
          ]
        )
      end

      it "sets rendered segment, not requested" do
        res = call MyApp, env("/users/1", "HTTP_ACCEPT" => "*/*")
        expect(res).to eq([{ hola: "1" }.to_json])

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#show<sk-segment>json</sk-segment>")
      end

      it "sets correct segment for exceptions" do
        # Turn off for this test, since it will log a ton, due to the mock
        ENV["SKYLIGHT_RAISE_ON_ERROR"] = nil

        # TODO: This native_span_set_exception stuff should probably get its own test
        # NOTE: This tests handling by the Subscriber. The Middleware probe may catch the exception again.
        args = [anything]
        args << (Rails::VERSION::MAJOR >= 5 ? an_instance_of(RuntimeError) : nil)
        args << %w[RuntimeError Fail!]

        allow_any_instance_of(Skylight::Trace).to receive(:native_span_set_exception).and_call_original

        expect_any_instance_of(Skylight::Trace).to receive(:native_span_set_exception).with(*args).and_call_original

        res = call MyApp, env("/users/failure")
        expect(res[0]).to start_with("failsafe response:"), "exceptions_app should have handled the response"

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq(
          "UsersController#failure#{error_segment}"
        ), "the original controller name should persist, despite being handled by exceptions_app"
      end

      it "sets correct segment for handled exceptions" do
        status, _headers, body = call_full MyApp, env("/users/handled_failure")
        expect(status).to eq(418)
        expect(body).to eq([{ error: "Handled!" }.to_json])

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]

        expect(endpoint.name).to eq("UsersController#handled_failure#{error_segment}")
      end

      it "sets correct segment for `head`" do
        status, _headers, body = call_full MyApp, env("/users/header")
        expect(status).to eq(200)
        expect(body[0].strip).to eq("") # Some Rails versions have a space, some don't

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]

        expect(endpoint.name).to eq("UsersController#header<sk-segment>html</sk-segment>")

        expect(endpoint.traces.count).to eq(1)
        trace = endpoint.traces[0]
        names = trace.filter_spans.map { |s| s.event.category }

        expect(names.length).to be >= 3
        expect(names).to include("app.zomg")
        expect(names[0]).to eq("app.rack.request")
      end

      it "sets correct segment for 4xx responses" do
        status, _headers, body = call_full MyApp, env("/users/not_found")
        expect(body).to eq(["failsafe response: resource not found"])
        expect(status).to eq(404)

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#not_found#{error_segment}")
      end

      it "sets correct segment for 5xx responses" do
        status, _headers, body = call_full MyApp, env("/users/status?status=500")
        expect(status).to eq(500)
        expect(body).to eq(["500"])

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#status<sk-segment>error</sk-segment>")
      end

      it "sets correct segment when no template is found" do
        status, _headers, body = call_full MyApp, env("/users/no_template")

        if Rails.version =~ /^4\./
          expect(status).to eq(500)
        else
          expect(status).to eq(406)
        end

        expect(body[0]).to be_blank

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#no_template<sk-segment>error</sk-segment>")
      end

      it "sets correct segment with variant" do
        res = call MyApp, env("/users/1.json?tablet=1")
        expect(res).to eq([{ hola_tablet: "1" }.to_json])

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#show<sk-segment>json+tablet</sk-segment>")
      end

      it "sets correct segment for `head` with variant" do
        status, _headers, body = call_full MyApp, env("/users/header?tablet=1", "HTTP_ACCEPT" => "application/json")
        expect(status).to eq(200)
        expect(body[0].strip).to eq("") # Some Rails versions have a space, some don't

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("UsersController#header<sk-segment>json+tablet</sk-segment>")
      end

      it "can instrument metal controllers" do
        call MyApp, env("/metal")

        server.wait resource: "/report"

        batch = server.reports[0]
        expect(batch).not_to be nil
        expect(batch.endpoints.count).to eq(1)
        endpoint = batch.endpoints[0]
        expect(endpoint.name).to eq("MetalController#show<sk-segment>html</sk-segment>")
        expect(endpoint.traces.count).to eq(1)
        trace = endpoint.traces[0]

        names = trace.filter_spans.map { |s| s.event.category }

        expect(names.length).to be >= 1
        expect(names[0]).to eq("app.rack.request")
      end

      it "correctly assigns endpoint names when ActiveJob is run synchronously" do
        call MyApp, env("/users/inline_job")

        server.wait(resource: "/report")
        endpoint = server.reports[0].endpoints[0]
        endpoint_name = "UsersController#inline_job"
        expect(endpoint.name).to eq("#{endpoint_name}<sk-segment>json</sk-segment>")

        trace = endpoint.traces.first
        spans = trace.filter_spans.last(4)

        expect(spans.map { |s| s.event.title }).to eq(
          [router_name, endpoint_name, "Check authorization", "MyApplicationJob"]
        )
      end

      it "sets correct segment and endpoint for before_action redirects" do
        call MyApp, env("/users/before_action_redirect")

        server.wait(resource: "/report")
        endpoint = server.reports[0].endpoints[0]

        endpoint_name = "UsersController#before_action_redirect"
        segment = "redirect"
        expect(endpoint.name).to eq("#{endpoint_name}<sk-segment>#{segment}</sk-segment>")
      end

      it "sets correct segment and endpoint for action redirect" do
        call MyApp, env("/users/action_redirect")

        server.wait(resource: "/report")
        endpoint = server.reports[0].endpoints[0]

        endpoint_name = "UsersController#action_redirect"
        segment = "redirect"
        expect(endpoint.name).to eq("#{endpoint_name}<sk-segment>#{segment}</sk-segment>")
      end

      it "sets correct segment and endpoint for send_file" do
        call MyApp, env("/users/send_png")

        server.wait(resource: "/report")
        endpoint = server.reports[0].endpoints[0]

        endpoint_name = "UsersController#send_png"
        segment = "png"
        expect(endpoint.name).to eq("#{endpoint_name}<sk-segment>#{segment}</sk-segment>")
      end

      it "sets correct segment and endpoint for not_modified" do
        call MyApp, env("/users/not_modified")

        server.wait(resource: "/report")
        endpoint = server.reports[0].endpoints[0]

        endpoint_name = "UsersController#not_modified"
        segment = "not modified"
        expect(endpoint.name).to eq("#{endpoint_name}<sk-segment>#{segment}</sk-segment>")
      end

      context "source location" do
        before { use_spec_root! }

        it "sets source_location for action" do
          call MyApp, env("/users")

          server.wait(resource: "/report")

          report = server.reports.first

          source_locations = report.source_locations
          trace = report.dig(:endpoints, 0, :traces, 0)

          source_file = Pathname.new(__FILE__).relative_path_from(spec_root).to_s
          source_file_index = source_locations.index(source_file)

          expect(trace.spans).to include(
            a_span_including(
              event: an_exact_event(category: "app.controller.request", title: "UsersController#index"),
              annotations:
                array_including(an_annotation(:SourceLocation, "#{source_file_index}:#{UsersController::INDEX_LINE}"))
            )
          )
        end

        context "with active_record" do
          def user_migration
            base = ActiveRecord::Migration
            base = base::Current if defined?(base::Current)

            Class.new(base) do
              def self.up
                create_table :users, force: true do |table|
                  table.string :username
                  table.timestamps
                end
              end

              def self.down
                drop_table :users
              end
            end
          end

          around { |example| with_sqlite(migration: user_migration, &example) }

          it "finds multiple source_locations for repeated queries" do
            call MyApp, env("/users?active_record=true")

            server.wait(resource: "/report")

            report = server.reports.first
            trace = report.dig(:endpoints, 0, :traces, 0)

            spans = trace.spans.select { |span| span.event.category == "db.sql.query" }

            source_locations = spans.map { |span| report.source_location(span) }

            source_file = Pathname.new(__FILE__).relative_path_from(spec_root).to_s
            base_line = UsersController::INDEX_DB_LINE
            expect(source_locations[0]).to eq("#{source_file}:#{base_line + 1}")
            expect(source_locations[1]).to eq("#{source_file}:#{base_line + 5}")
          end
        end
      end
    end

    context "activated from application.rb", :http, :agent do
      def pre_boot
      end

      before :each do
        @original_environments = MyApp.config.skylight.environments.clone
        MyApp.config.skylight.environments << "development"

        stub_config_validation
        stub_session_request

        pre_boot
        boot
      end

      after :each do
        MyApp.config.skylight.environments = @original_environments
      end

      it_behaves_like "with agent"
    end

    context "activated from ENV", :http, :agent do
      def pre_boot
      end

      before :each do
        ENV["SKYLIGHT_ENABLED"] = "true"

        stub_config_validation
        stub_session_request

        pre_boot
        boot
      end

      it_behaves_like "with agent [minimal]"
    end

    shared_examples "without agent" do
      before :each do
        # Sanity check that we are indeed running without an active agent
        expect(Skylight.instrumenter).to be_nil
      end

      it "allows calls to Skylight.instrument" do
        expect(call(MyApp, env("/users"))).to eq(["Hello"])
      end

      it "supports Skylight::Helpers" do
        expect(call(MyApp, env("/users/1"))).to eq(["Hola: 1"])
      end
    end

    context "without configuration" do
      before :each do
        boot
      end

      it_behaves_like "without agent"
    end

    context "deactivated from ENV" do
      def pre_boot
      end

      before :each do
        ENV["SKYLIGHT_ENABLED"] = "false"

        @original_environments = MyApp.config.skylight.environments.clone
        MyApp.config.skylight.environments << "development"

        pre_boot
        boot
      end

      after :each do
        MyApp.config.skylight.environments = @original_environments
      end

      it_behaves_like "without agent"
    end

    context "instrument_method" do
      it "maintains privacy" do
        expect(UsersController.private_method_defined?(:authorized?)).to be_truthy
      end

      it "maintains protectedness" do
        expect(UsersController.protected_method_defined?(:unused)).to be_truthy
      end
    end

    def call_full(app, env)
      resp = app.call(env)
      consume(resp)
      resp
    end

    def call(app, env)
      call_full(app, env)[2]
    end

    def env(path = "/", opts = {})
      Rack::MockRequest.env_for(path, { "HTTP_HOST" => "localhost" }.merge(opts))
    end

    def consume(resp)
      data = []
      resp[2].each { |p| data << p }
      resp[2].close if resp[2].respond_to?(:close)
      resp[2] = data
      resp
    end

    def expect_caught_response(body)
      expect(body).to eq(CatchingMiddleware.thrown_response.last.last)
    end
  end
end
