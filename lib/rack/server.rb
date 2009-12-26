require 'optparse'

module Rack
  class Server
    class Options
      def parse!(args)
        options = {}
        opt_parser = OptionParser.new("", 24, '  ') do |opts|
          opts.banner = "Usage: rackup [ruby options] [rack options] [rackup config]"

          opts.separator ""
          opts.separator "Ruby options:"

          lineno = 1
          opts.on("-e", "--eval LINE", "evaluate a LINE of code") { |line|
            eval line, TOPLEVEL_BINDING, "-e", lineno
            lineno += 1
          }

          opts.on("-d", "--debug", "set debugging flags (set $DEBUG to true)") {
            options[:debug] = true
          }
          opts.on("-w", "--warn", "turn warnings on for your script") {
            options[:warn] = true
          }

          opts.on("-I", "--include PATH",
                  "specify $LOAD_PATH (may be used more than once)") { |path|
            options[:include] = path.split(":")
          }

          opts.on("-r", "--require LIBRARY",
                  "require the library, before executing your script") { |library|
            options[:require] = library
          }

          opts.separator ""
          opts.separator "Rack options:"
          opts.on("-s", "--server SERVER", "serve using SERVER (webrick/mongrel)") { |s|
            options[:server] = s
          }

          opts.on("-o", "--host HOST", "listen on HOST (default: 0.0.0.0)") { |host|
            options[:Host] = host
          }

          opts.on("-p", "--port PORT", "use PORT (default: 9292)") { |port|
            options[:Port] = port
          }

          opts.on("-c", "--chdir DIR", "Change to dir before starting") { |dir|
            options[:chdir] = ::File.expand_path(dir)
          }

          opts.on("-E", "--env ENVIRONMENT", "use ENVIRONMENT for defaults (default: development)") { |e|
            options[:environment] = e
          }

          opts.on("-D", "--daemonize", "run daemonized in the background") { |d|
            options[:daemonize] = d ? true : false
          }

          opts.on("-P", "--pid FILE", "file to store PID (default: rack.pid)") { |f|
            options[:pid] = f
          }

          opts.separator ""
          opts.separator "Common options:"

          opts.on_tail("-h", "--help", "Show this message") do
            puts opts
            exit
          end

          opts.on_tail("--version", "Show version") do
            puts "Rack #{Rack.version}"
            exit
          end
        end
        opt_parser.parse! args
        options[:config] = args.last if args.last
        options
      end
    end

    def self.start
      new.start
    end

    attr_accessor :options

    def initialize(options = nil)
      @options = options
    end

    def options
      @options ||= parse_options(ARGV)
    end

    def default_options
      {
        :chdir       => Dir.pwd,
        :environment => "development",
        :pid         => nil,
        :Port        => 9292,
        :Host        => "0.0.0.0",
        :AccessLog   => [],
        :config      => "config.ru"
      }
    end

    def app
      @app ||= begin
        if !::File.exist? options[:config]
          abort "configuration #{options[:config]} not found"
        end

        app, options = Rack::Builder.parse_file(self.options[:config], opt_parser)
        self.options.merge! options
        app
      end
    end

    def self.middleware
      @middleware ||= begin
        m = Hash.new {|h,k| h[k] = []}
        m["deployment"].concat  [lambda {|server| server.server =~ /CGI/ ? nil : [Rack::CommonLogger, $stderr] }]
        m["development"].concat m["deployment"] + [[Rack::ShowExceptions], [Rack::Lint]]
        m
      end
    end

    def middleware
      self.class.middleware
    end

    def start
      Dir.chdir(options[:chdir])

      if options[:debug]
        $DEBUG = true
        require 'pp'
        p options[:server]
        pp wrapped_app
        pp app
      end

      if options[:warn]
        $-w = true
      end

      if includes = options[:include]
        $LOAD_PATH.unshift *includes
      end

      if library = options[:require]
        require library
      end

      daemonize_app if options[:daemonize]
      write_pid if options[:pid]
      server.run wrapped_app, options
    end

    def server
      @_server ||= Rack::Handler.get(options[:server]) || Rack::Handler.default
    end

    private
      def parse_options(args)
        options = default_options

        # Don't evaluate CGI ISINDEX parameters.
        # http://hoohoo.ncsa.uiuc.edu/cgi/cl.html
        args.clear if ENV.include?("REQUEST_METHOD")

        options.merge! opt_parser.parse! args
        options
      end

      def opt_parser
        Options.new
      end

      def build_app(app)
        middleware[options[:environment]].reverse_each do |middleware|
          middleware = middleware.call(self) if middleware.respond_to?(:call)
          next unless middleware
          klass = middleware.shift
          app = klass.new(app, *middleware)
        end
        app
      end

      def wrapped_app
        @wrapped_app ||= build_app app
      end

      def daemonize_app
        if RUBY_VERSION < "1.9"
          exit if fork
          Process.setsid
          exit if fork
          Dir.chdir "/"
          ::File.umask 0000
          STDIN.reopen "/dev/null"
          STDOUT.reopen "/dev/null", "a"
          STDERR.reopen "/dev/null", "a"
        else
          Process.daemon
        end
      end

      def write_pid
        ::File.open(options[:pid], 'w'){ |f| f.write("#{Process.pid}") }
        at_exit { ::File.delete(options[:pid]) if ::File.exist?(options[:pid]) }
      end
  end
end
