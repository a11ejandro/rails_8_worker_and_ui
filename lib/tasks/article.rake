# frozen_string_literal: true

# Helper module for article generation tasks
module ArticleTaskHelpers
  DEFAULTS = {
    rows: "100000",
    seed: "123",
    dist: "survey",
    per_pages: "1,10,25,50,100,250,500,1000,10000,100000",
    runs: "30",
    page: "1",
    handlers: "ruby,go,python,node",
    mode: "enqueue",
    schedule: "serial_by_handler",
    wait_timeout: 7200,
    wait_poll: 2.0
  }.freeze

  class Configuration
    attr_reader :rows, :seed, :dist, :per_pages, :runs, :page,
                :handlers, :mode, :schedule, :wait, :wait_timeout, :wait_poll

    def initialize(args = {}, env = ENV)
      @rows = parse_value(args[:rows], env["ROWS"], DEFAULTS[:rows])
      @seed = parse_value(args[:seed], env["SEED"], DEFAULTS[:seed])
      @dist = parse_value(args[:dist], env["DIST"], DEFAULTS[:dist])
      @per_pages = parse_list(args[:per_pages], env["PER_PAGES"], DEFAULTS[:per_pages])
      @runs = parse_value(args[:runs], env["RUNS"], DEFAULTS[:runs]).to_i
      @page = parse_value(args[:page], env["PAGE"], DEFAULTS[:page]).to_i
      @handlers = parse_list(args[:handlers], env["HANDLERS"], DEFAULTS[:handlers])
      @mode = parse_value(args[:mode], env["MODE"], DEFAULTS[:mode])
      @schedule = parse_value(args[:schedule], env["SCHEDULE"], DEFAULTS[:schedule])
      
      wait_default = @schedule == "serial_by_handler" ? "true" : "false"
      @wait = parse_value(args[:wait], env["WAIT"], wait_default) == "true"
      @wait_timeout = parse_value(args[:wait_timeout], env["WAIT_TIMEOUT_SECONDS"], DEFAULTS[:wait_timeout]).to_i
      @wait_poll = parse_value(args[:wait_poll], env["WAIT_POLL_SECONDS"], DEFAULTS[:wait_poll]).to_f
    end

    def per_page_integers
      @per_pages.split(",").map(&:strip).reject(&:empty?).map(&:to_i)
    end

    def handler_list
      @handlers.split(",").map(&:strip).reject(&:empty?)
    end

    private

    def parse_value(arg, env_val, default)
      (arg || env_val || default).to_s
    end

    def parse_list(arg, env_val, default)
      parse_value(arg, env_val, default)
    end
  end

  class WorkerEnqueuer
    def self.enqueue(handler_type, test_run_id, mode)
      case handler_type
      when "ruby"
        enqueue_ruby(test_run_id, mode)
      when "go"
        enqueue_go(test_run_id)
      when "node"
        enqueue_node(test_run_id)
      when "python"
        enqueue_python(test_run_id)
      else
        raise ArgumentError, "Unknown handler type: #{handler_type.inspect}"
      end
    end

    def self.enqueue_ruby(test_run_id, mode)
      if mode == "inline"
        RubyWorker.new.perform(test_run_id)
        :inline
      else
        RubyWorker.perform_async(test_run_id)
        :enqueued
      end
    end

    def self.enqueue_go(test_run_id)
      p 'enqueueing go, test_run_id:', test_run_id
      Sidekiq::Client.push("class" => "GoWorker", "queue" => "go", "args" => [test_run_id])
      :enqueued
    end

    def self.enqueue_node(test_run_id)
      Sidekiq::Client.push("class" => "NodeWorker", "queue" => "node", "args" => [test_run_id])
      :enqueued
    end

    def self.enqueue_python(test_run_id)
      PythonWorkerClient.enqueue(test_run_id)
      :enqueued
    end
  end

  class CompletionWaiter
    def self.wait_for(handler_ids:, expected_results:, timeout_seconds:, poll_seconds:, queue_names: [])
      start = Time.now
      last_count = -1
      last_log_at = Time.at(0)
      log_every_seconds = [10.0, poll_seconds.to_f].max

      loop do
        count = TestResult.joins(:test_run).where(test_runs: { handler_id: handler_ids }).count

        now = Time.now
        should_log = (count != last_count) || (now - last_log_at) >= log_every_seconds

        if should_log
          elapsed = (now - start).round(1)
          extras = queue_depth_summary(queue_names)
          suffix = extras.empty? ? "" : " | #{extras}"
          puts "[waiting] progress #{count}/#{expected_results} elapsed=#{elapsed}s#{suffix}"
          last_count = count
          last_log_at = now
        end

        return count if count >= expected_results

        if (now - start) > timeout_seconds
          raise "Timeout waiting for results: #{count}/#{expected_results} after #{timeout_seconds}s"
        end

        sleep poll_seconds
      end
    end

    def self.queue_depth_summary(queue_names)
      names = Array(queue_names).map(&:to_s).map(&:strip).reject(&:empty?)
      return "" if names.empty?
      return "" unless defined?(Sidekiq)

      depths = Sidekiq.redis do |redis|
        names.map do |q|
          key = "queue:#{q}"
          "#{key}=#{redis.llen(key)}"
        end
      end

      depths.join(" ")
    rescue StandardError
      ""
    end

    private_class_method :queue_depth_summary
  end

  class BenchmarkOrchestrator
    attr_reader :config, :enqueued_count, :inline_count

    def initialize(config)
      @config = config
      @enqueued_count = 0
      @inline_count = 0
    end

    def execute_benchmarks
      tasks = Task.where(selected: true).order(:name)

      if config.schedule == "serial_by_handler"
        execute_serial_by_handler(tasks)
      else
        execute_parallel(tasks)
      end

      log_summary
    end

    private

    def execute_serial_by_handler(tasks)
      config.handler_list.each do |handler_type|
        puts "[orchestrator] starting handler=#{handler_type}"
        
        handler_ids, expected_results = create_and_enqueue_for_handler(tasks, handler_type)
        
        wait_if_needed(handler_type, handler_ids, expected_results)
      end
    end

    def execute_parallel(tasks)
      tasks.find_each do |task|
        config.handler_list.each do |handler_type|
          create_and_enqueue_for_task(task, handler_type)
        end
      end
    end

    def create_and_enqueue_for_handler(tasks, handler_type)
      handler_ids = []
      expected_results = 0

      tasks.find_each do |task|
        handler = Handler.create!(task: task, handler_type: handler_type)
        handler_ids << handler.id
        expected_results += task.runs

        enqueue_runs_for_handler(handler, task.runs)
      end

      [handler_ids, expected_results]
    end

    def create_and_enqueue_for_task(task, handler_type)
      handler = Handler.create!(task: task, handler_type: handler_type)
      enqueue_runs_for_handler(handler, task.runs)
    end

    def enqueue_runs_for_handler(handler, runs)
      runs.times do |run|
        test_run = TestRun.create!(handler: handler, consequent_number: run)
        outcome = WorkerEnqueuer.enqueue(handler.handler_type, test_run.id, config.mode)
        
        outcome == :inline ? @inline_count += 1 : @enqueued_count += 1
      end
    end

    def wait_if_needed(handler_type, handler_ids, expected_results)
      return unless config.wait
      return if inline_ruby_only?(handler_type)

      puts "[orchestrator] waiting handler=#{handler_type} expected_results=#{expected_results}"
      queue_names = sidekiq_queue_names_for(handler_type)
      CompletionWaiter.wait_for(
        handler_ids: handler_ids,
        expected_results: expected_results,
        timeout_seconds: config.wait_timeout,
        poll_seconds: config.wait_poll,
        queue_names: queue_names
      )
    end

    def inline_ruby_only?(handler_type)
      config.mode == "inline" && handler_type == "ruby"
    end

    def sidekiq_queue_names_for(handler_type)
      case handler_type
      when "ruby"
        ["default"]
      when "go"
        ["go"]
      when "node"
        ["node"]
      else
        []
      end
    end

    def log_summary
      puts "[orchestrator] inline_completed=#{@inline_count} enqueued=#{@enqueued_count}"
    end
  end
end

namespace :article do
  desc "Seed deterministic samples via db:seed. Args: rows (default 100000), seed (default 123), dist (uniform|normal|survey)"
  task :seed_samples, [:rows, :seed, :dist] => :environment do |_t, args|
    config = ArticleTaskHelpers::Configuration.new(args)
    
    ENV["ROWS"] = config.rows
    ENV["SEED"] = config.seed
    ENV["DIST"] = config.dist

    Rails.application.load_seed
  end

  desc "Create (or replace) standard tasks. Args: per_pages (comma list), runs (default 30), page (default 1)"
  task :setup_tasks, [:per_pages, :runs, :page] => :environment do |_t, args|
    config = ArticleTaskHelpers::Configuration.new(args)

    puts "[article:setup_tasks] per_pages=#{config.per_page_integers.inspect} runs=#{config.runs} page=#{config.page}"

    # Delete in FK-safe order (children before parents)
    Statistic.delete_all
    TestResult.delete_all
    TestRun.delete_all
    Handler.delete_all
    Task.delete_all

    config.per_page_integers.each do |per_page|
      Task.create!(
        name: per_page.to_s,
        page: config.page,
        per_page: per_page,
        runs: config.runs,
        selected: true
      )
    end

    puts "[article:setup_tasks] done. tasks=#{Task.count}"
  end

  desc "Export selected-tasks long CSVs into docs/data/."
  task export_selected_csv: :environment do
    out_dir = Rails.root.join("docs", "data")
    FileUtils.mkdir_p(out_dir)

    tasks = Task.where(selected: true)

    durations_csv = SelectedTasksDurationCsvExporter.new(tasks: tasks).generate
    memory_csv = SelectedTasksMemoryCsvExporter.new(tasks: tasks).generate

    durations_path = out_dir.join("durations_selected.csv")
    memory_path = out_dir.join("memory_selected.csv")

    durations_path.write(durations_csv)
    memory_path.write(memory_csv)

    puts "[article:export_selected_csv] wrote #{durations_path}"
    puts "[article:export_selected_csv] wrote #{memory_path}"
  end

  desc "Generate static SVG figures for the article from docs/data/*.csv"
  # Usage:
  #   bundle exec rails "article:generate_figures[/path/to/durations.csv,/path/to/memory.csv,/path/to/out_dir]"
  # or via env vars:
  #   DURATIONS_PATH=... MEMORY_PATH=... FIGURES_OUT_DIR=... bundle exec rails article:generate_figures
  task :generate_figures, %i[durations memory out] => :environment do |_t, args|
    require Rails.root.join("lib", "article", "figure_generator")

    default_durations = Rails.root.join("docs", "data", "durations_selected.csv")
    default_memory = Rails.root.join("docs", "data", "memory_selected.csv")
    default_out = Rails.root.join("docs", "figures")

    durations_path = Pathname.new((args[:durations] || ENV["DURATIONS_PATH"] || default_durations).to_s)
    memory_path = Pathname.new((args[:memory] || ENV["MEMORY_PATH"] || default_memory).to_s)
    out_dir = Pathname.new((args[:out] || ENV["FIGURES_OUT_DIR"] || default_out).to_s)

    FileUtils.mkdir_p(out_dir)

    puts "[article:generate_figures] durations: #{durations_path}"
    puts "[article:generate_figures] memory:    #{memory_path}"
    puts "[article:generate_figures] out:       #{out_dir}"

    Article::FigureGenerator.generate!(
      durations_path: durations_path.to_s,
      memory_path: memory_path.to_s,
      out_dir: out_dir.to_s
    )
  end


  desc "One-command pipeline: seed samples, create tasks, enqueue or run inline, and (when possible) export CSV. Configure via env vars."
  task generate_all: :environment do
    config = ArticleTaskHelpers::Configuration.new

    puts "[article:generate_all] Configuration:"
    puts "  samples: rows=#{config.rows} seed=#{config.seed} dist=#{config.dist}"
    puts "  tasks: per_pages=#{config.per_pages} runs=#{config.runs} page=#{config.page}"
    puts "  execution: handlers=#{config.handlers} mode=#{config.mode} schedule=#{config.schedule}"
    puts "  waiting: wait=#{config.wait} timeout=#{config.wait_timeout}s poll=#{config.wait_poll}s"

    # 1. Seed samples
    Rake::Task["article:seed_samples"].reenable
    Rake::Task["article:seed_samples"].invoke(config.rows, config.seed, config.dist)

    # 2. Setup tasks
    Rake::Task["article:setup_tasks"].reenable
    Rake::Task["article:setup_tasks"].invoke(config.per_pages, config.runs, config.page)

    # 3. Execute benchmarks
    orchestrator = ArticleTaskHelpers::BenchmarkOrchestrator.new(config)
    orchestrator.execute_benchmarks

    # 4. Export and generate figures if appropriate
    should_export = inline_ruby_only?(config) || config.wait
    
    if should_export
      export_and_generate_figures
    else
      puts "[article:generate_all] run article:export_selected_csv after workers finish"
    end
  end

  private

  def inline_ruby_only?(config)
    config.mode == "inline" && config.handler_list == ["ruby"]
  end

  def export_and_generate_figures
    Rake::Task["article:export_selected_csv"].reenable
    Rake::Task["article:export_selected_csv"].invoke
    puts "[article:generate_all] exported CSV"

    Rake::Task["article:generate_figures"].reenable
    Rake::Task["article:generate_figures"].invoke
    puts "[article:generate_all] generated figures"
  end
end
