require 'puppet'
require 'optparse'

# This class handles all the aspects of a Puppet application/executable
# * setting up options
# * setting up logs
# * choosing what to run
# * representing execution status
#
# === Usage
# The application is a Puppet::Application object that register itself in the list
# of available application. Each application needs a +name+ and a getopt +options+
# description array.
#
# The executable uses the application object like this:
#      Puppet::Application[:example].run
#
#
# Puppet::Application.new(:example) do
#
#     preinit do
#         # perform some pre initialization
#         @all = false
#     end
#
#     # dispatch is called to know to what command to call
#     dispatch do
#         ARGV.shift
#     end
#
#     option("--arg ARGUMENT") do |v|
#         @args << v
#     end
#
#     option("--debug", "-d") do |v|
#         @debug = v
#     end
#
#     option("--all", "-a:) do |v|
#         @all = v
#     end
#
#     unknown do |opt,arg|
#         # last chance to manage an option
#         ...
#         # let's say to the framework we finally handle this option
#         true
#     end
#
#     command(:read) do
#         # read action
#     end
#
#     command(:write) do
#         # writeaction
#     end
#
# end
#
# === Preinit
# The preinit block is the first code to be called in your application, before option parsing,
# setup or command execution.
#
# === Options
# Puppet::Application uses +OptionParser+ to manage the application options.
# Options are defined with the +option+ method to which are passed various
# arguments, including the long option, the short option, a description...
# Refer to +OptionParser+ documentation for the exact format.
# * If the option method is given a block, this one will be called whenever
# the option is encountered in the command-line argument.
# * If the option method has no block, a default functionnality will be used, that
# stores the argument (or true/false if the option doesn't require an argument) in
# the global (to the application) options array.
# * If a given option was not defined by a the +option+ method, but it exists as a Puppet settings:
#  * if +unknown+ was used with a block, it will be called with the option name and argument
#  * if +unknown+ wasn't used, then the option/argument is handed to Puppet.settings.handlearg for
#    a default behavior
#
# --help is managed directly by the Puppet::Application class, but can be overriden.
#
# === Setup
# Applications can use the setup block to perform any initialization.
# The defaul +setup+ behaviour is to: read Puppet configuration and manage log level and destination
#
# === What and how to run
# If the +dispatch+ block is defined it is called. This block should return the name of the registered command
# to be run.
# If it doesn't exist, it defaults to execute the +main+ command if defined.
#
# === Execution state
# The class attributes/methods of Puppet::Application serve as a global place to set and query the execution
# status of the application: stopping, restarting, etc.  The setting of the application status does not directly
# aftect its running status; it's assumed that the various components within the application will consult these
# settings appropriately and affect their own processing accordingly.  Control operations (signal handlers and
# the like) should set the status appropriately to indicate to the overall system that it's the process of
# stopping or restarting (or just running as usual).
#
# So, if something in your application needs to stop the process, for some reason, you might consider:
#
#  def stop_me!
#      # indicate that we're stopping
#      Puppet::Application.stop!
#      # ...do stuff...
#  end
#
# And, if you have some component that involves a long-running process, you might want to consider:
#
#  def my_long_process(giant_list_to_munge)
#      giant_list_to_munge.collect do |member|
#          # bail if we're stopping
#          return if Puppet::Application.stop_requested?
#          process_member(member)
#      end
#  end
class Puppet::Application
    include Puppet::Util

    BINDIRS = File.expand_path(File.dirname(__FILE__)) + '/../../{sbin,bin}'

    @@applications = {}
    def self.applications; @@applications end

    class << self
        include Puppet::Util

        attr_accessor :run_status

        def clear!
            self.run_status = nil
        end

        def stop!
            self.run_status = :stop_requested
        end

        def restart!
            self.run_status = :restart_requested
        end

        # Indicates that Puppet::Application.restart! has been invoked and components should
        # do what is necessary to facilitate a restart.
        def restart_requested?
            :restart_requested == run_status
        end

        # Indicates that Puppet::Application.stop! has been invoked and components should do what is necessary
        # for a clean stop.
        def stop_requested?
            :stop_requested == run_status
        end

        # Indicates that one of stop! or start! was invoked on Puppet::Application, and some kind of process
        # shutdown/short-circuit may be necessary.
        def interrupted?
            [:restart_requested, :stop_requested].include? run_status
        end

        # Indicates that Puppet::Application believes that it's in usual running mode (no stop/restart request
        # currently active).
        def clear?
            run_status.nil?
        end

        # Only executes the given block if the run status of Puppet::Application is clear (no restarts, stops,
        # etc. requested).
        # Upon block execution, checks the run status again; if a restart has been requested during the block's
        # execution, then controlled_run will send a new HUP signal to the current process.
        # Thus, long-running background processes can potentially finish their work before a restart.
        def controlled_run(&block)
            return unless clear?
            result = block.call
            Process.kill(:HUP, $$) if restart_requested?
            result
        end
    end

    attr_reader :options, :opt_parser

    def self.[](name)
        name = symbolize(name)
        @@applications[name]
    end

    def should_parse_config
        @parse_config = true
    end

    def should_not_parse_config
        @parse_config = false
    end

    def should_parse_config?
        unless @parse_config.nil?
            return @parse_config
        end
        @parse_config = true
    end

    # used to declare a new command
    def command(name, &block)
        meta_def(symbolize(name), &block)
    end

    # used as a catch-all for unknown option
    def unknown(&block)
        meta_def(:handle_unknown, &block)
    end

    # used to declare code that handle an option
    def option(*options, &block)
        long = options.find { |opt| opt =~ /^--/ }.gsub(/^--(?:\[no-\])?([^ =]+).*$/, '\1' ).gsub('-','_')
        fname = "handle_#{long}"
        if (block_given?)
            meta_def(symbolize(fname), &block)
        else
            meta_def(symbolize(fname)) do |value|
                self.options["#{long}".to_sym] = value
            end
        end
        @opt_parser.on(*options) do |value|
            self.send(symbolize(fname), value)
        end
    end

    # used to declare accessor in a more natural way in the
    # various applications
    def attr_accessor(*args)
        args.each do |arg|
            meta_def(arg) do
                instance_variable_get("@#{arg}".to_sym)
            end
            meta_def("#{arg}=") do |value|
                instance_variable_set("@#{arg}".to_sym, value)
            end
        end
    end

    # used to declare code run instead the default setup
    def setup(&block)
        meta_def(:run_setup, &block)
    end

    # used to declare code to choose which command to run
    def dispatch(&block)
        meta_def(:get_command, &block)
    end

    # used to execute code before running anything else
    def preinit(&block)
        meta_def(:run_preinit, &block)
    end

    def initialize(name, banner = nil, &block)
        @opt_parser = OptionParser.new(banner)

        @name = symbolize(name)

        init_default

        @options = {}

        instance_eval(&block) if block_given?

        @@applications[@name] = self
    end

    # initialize default application behaviour
    def init_default
        setup do
            default_setup
        end

        dispatch do
            :main
        end

        # empty by default
        preinit do
        end

        option("--version", "-V") do |arg|
            puts "%s" % Puppet.version
            exit
        end

        option("--help", "-h") do |v|
            help
        end
    end

    # This is the main application entry point
    def run
        exit_on_fail("initialize") { run_preinit }
        exit_on_fail("parse options") { parse_options }
        exit_on_fail("parse configuration file") { Puppet.settings.parse } if should_parse_config?
        exit_on_fail("prepare for execution") { run_setup }
        exit_on_fail("run") { run_command }
    end

    def main
        raise NotImplementedError, "No valid command or main"
    end

    def run_command
        if command = get_command() and respond_to?(command)
            send(command)
        else
            main
        end
    end

    def default_setup
        # Handle the logging settings
        if options[:debug] or options[:verbose]
            Puppet::Util::Log.newdestination(:console)
            if options[:debug]
                Puppet::Util::Log.level = :debug
            else
                Puppet::Util::Log.level = :info
            end
        end

        unless options[:setdest]
            Puppet::Util::Log.newdestination(:syslog)
        end
    end

    def parse_options
        # get all puppet options
        optparse_opt = []
        optparse_opt = Puppet.settings.optparse_addargs(optparse_opt)

        # convert them to OptionParser format
        optparse_opt.each do |option|
            @opt_parser.on(*option) do |arg|
                handlearg(option[0], arg)
            end
        end

        # scan command line argument
        begin
            @opt_parser.parse!
        rescue OptionParser::ParseError => detail
            $stderr.puts detail
            $stderr.puts "Try '#{$0} --help'"
            exit(1)
        end
    end

    def handlearg(opt, arg)
        # rewrite --[no-]option to --no-option if that's what was given
        if opt =~ /\[no-\]/ and !arg
            opt = opt.gsub(/\[no-\]/,'no-')
        end
        # otherwise remove the [no-] prefix to not confuse everybody
        opt = opt.gsub(/\[no-\]/, '')
        unless respond_to?(:handle_unknown) and send(:handle_unknown, opt, arg)
            # Puppet.settings.handlearg doesn't handle direct true/false :-)
            if arg.is_a?(FalseClass)
                arg = "false"
            elsif arg.is_a?(TrueClass)
                arg = "true"
            end
            Puppet.settings.handlearg(opt, arg)
        end
    end

    # this is used for testing
    def self.exit(code)
        exit(code)
    end

    def help
        if Puppet.features.usage?
            # RH:FIXME: My goodness, this is ugly.
            ::RDoc.const_set("PuppetSourceFile", @name)
            def (::RDoc).caller
                docfile = `grep -l 'Puppet::Application\\[:#{::RDoc::PuppetSourceFile}\\]' #{BINDIRS}/*`.chomp
                super << "#{docfile}:0"
            end
            ::RDoc::usage && exit
        else
            puts "No help available unless you have RDoc::usage installed"
            exit
        end
    rescue Errno::ENOENT
        puts "No help available for puppet #@name"
        exit
    end

    private

    def exit_on_fail(message, code = 1)
        begin
            yield
        rescue RuntimeError, NotImplementedError => detail
            puts detail.backtrace if Puppet[:trace]
            $stderr.puts "Could not %s: %s" % [message, detail]
            exit(code)
        end
    end
end
