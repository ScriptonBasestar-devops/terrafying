# frozen_string_literal: true

require 'fileutils'
require 'logger'
require 'pathname'
require 'securerandom'
require 'tempfile'

require 'terrafying/aws'
require 'terrafying/cli'
require 'terrafying/generator'
require 'terrafying/lock'
require 'terrafying/version'
require 'terrafying/state'

module Terrafying
  class Config
    attr_reader :path, :scope

    def initialize(path, options)
      @path = File.expand_path(path)
      @options = options
      @scope = options[:scope] || scope_for_path(@path)

      warn "Scope: #{@scope}"

      load(path)
    end

    def list
      Terrafying::Generator.resource_names
    end

    def json
      Terrafying::Generator.pretty_generate
    end

    def plan
      exit_code = 1
      with_config do
        with_state(mode: :read) do
          exit_code = exec_with_optional_target 'plan'
        end
      end
      exit_code
    end

    def graph
      exit_code = 1
      with_config do
        with_state(mode: :read) do
          exit_code = exec_with_optional_target 'graph'
        end
      end
      exit_code
    end

    def validate
      exit_code = 1
      with_config do
        with_state(mode: :read) do
          exit_code = exec_with_optional_target 'validate'
        end
      end
      exit_code
    end

    def apply
      exit_code = 1
      with_config do
        with_lock do
          with_state(mode: :update) do
            exit_code = exec_with_optional_target "apply -auto-approve -backup=- #{@dir}"
          end
        end
      end
      exit_code
    end

    def destroy
      exit_code = 1
      with_config do
        with_lock do
          with_state(mode: :update) do
            exit_code = stream_command("terraform destroy -backup=- #{@dir}")
          end
        end
      end
      exit_code
    end

    def show_state
      puts(State.store(self).get)
    end

    def use_remote_state
      with_lock do
        local = State.local(self)
        state = local.get
        State.remote(self).put(state) if state
        local.delete
      end
    end

    def use_local_state
      with_lock do
        remote = State.remote(self)
        state = remote.get
        State.local(self).put(state) if state
      end
    end

    def import(addr, id)
      exit_code = 1
      with_config do
        with_lock do
          with_state(mode: :update) do
            exit_code = exec_with_optional_target "import  -backup=- #{@dir} #{addr} #{id}"
          end
        end
      end
      exit_code
    end

    private

    def lock_timeout
      "-lock-timeout=#{@options[:lock_timeout]}" if @options[:lock_timeout]
    end

    def targets
      @options[:target].split(',').map { |target| "-target=#{target}" }.join(' ') if @options[:target]
    end

    def exec_with_optional_target(command, *args)
      exec_with_args(command, targets, lock_timeout, *args)
    end

    def exec_with_args(command, *args)
      stream_command("terraform #{command} #{args.join(' ')}")
    end

    def with_config(&block)
      abort('***** ERROR: You must have terraform installed to run this gem *****') unless terraform_installed?
      check_version
      name = File.basename(@path, '.*')
      dir = File.join(git_toplevel, 'tmp', SecureRandom.uuid)
      terraform_files = File.join(git_toplevel, '.terraform/')
      unless Dir.exist?(terraform_files)
        abort("***** ERROR: No .terraform directory found. Please run 'terraform init' to install plugins *****")
      end
      FileUtils.mkdir_p(dir)
      output_path = File.join(dir, name + '.tf.json')
      FileUtils.cp_r(terraform_files, dir)
      Dir.chdir(dir) do
        File.write(output_path, Terrafying::Generator.pretty_generate)
        yield block
      ensure
        FileUtils.rm_rf(dir) unless @options[:keep]
      end
    end

    def with_lock(&block)
      lock_id = nil
      begin
        lock = if @options[:no_lock]
                 Locks.noop
               else
                 Locks.dynamodb(scope)
               end

        lock_id = if @options[:force]
                    lock.steal
                  else
                    lock.acquire
                  end
        yield block

        # If block raises any exception we will still hold on to lock
        # after process exits. This is actually what we want as
        # terraform may have succeeded in updating some resources, but
        # not others so we need to manually get into a consistent
        # state and then re-run.
        lock.release(lock_id)
      end
    end

    def with_state(opts, &block)
      return yield(block) unless @options[:dynamodb]

      store = State.store(self)

      begin
        state = store.get
        File.write(State::STATE_FILENAME, state) if state
      rescue StandardError => e
        raise "Error retrieving state for config #{self}: #{e}"
      end

      yield block

      begin
        store.put(IO.read(State::STATE_FILENAME)) if opts[:mode] == :update
      rescue StandardError => e
        raise "Error updating state for config #{self}: #{e}"
      end
    end

    def scope_for_path(_path)
      top_level_path = Pathname.new(git_toplevel)
      Pathname.new(@path).relative_path_from(top_level_path).to_s
    end

    def git_toplevel
      @top_level ||= begin
                       top_level = `git rev-parse --show-toplevel`
                       raise "Unable to find .git directory top level for '#{@path}'" if top_level.empty?

                       File.expand_path(top_level.chomp)
                     end
    end

    def check_version
      if terraform_version != Terrafying::CLI_VERSION
        abort("***** ERROR: You must have v#{Terrafying::CLI_VERSION} of terraform installed to run any command (you are running v#{terraform_version}) *****")
      end
    end

    def terraform_installed?
      which('terraform')
    end

    def terraform_version
      `terraform -v`.split("\n").first.split('v').last
    end

    def stream_command(cmd)
      IO.popen(cmd) do |io|
        while (line = io.gets)
          puts line.gsub('\n', "\n").gsub('\\"', '"')
        end
      end
      $CHILD_STATUS.exitstatus
    end

    # Cross-platform way of finding an executable in the $PATH.
    #
    #   which('ruby') #=> /usr/bin/ruby
    def which(cmd)
      exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
      ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
        exts.each do |ext|
          exe = File.join(path, "#{cmd}#{ext}")
          return exe if File.executable?(exe) && !File.directory?(exe)
        end
      end
      nil
    end
  end
end
