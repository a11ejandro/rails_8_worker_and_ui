class RubyWorker
  include Sidekiq::Job

  def perform(test_run_id)
    test_run = TestRun.find(test_run_id)
    task = test_run.handler.task
    page_size = task.page_size
    page = task.page
    results = {}
    values = get_page_values(page, page_size)

    MemoryProfiler.start

    time = Benchmark.measure do
      results = CalculateStatistics.call(values)
    end

    memory_profiler = MemoryProfiler.stop

    TestResult.create!(**results, test_run: test_run, time: time.real, memory_usage: memory_profiler.total_allocated_memsize)
  end

  private

  def get_page_values(page, per_page)
    offset = per_page * ((page = page.to_i - 1) < 0 ? 0 : page)

    Sample.limit(per_page).offset(offset).pluck(:value)
  end
end