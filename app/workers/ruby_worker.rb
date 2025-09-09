class RubyWorker
  include Sidekiq::Job

  def perform(test_run_id)
    test_run = TestRun.find(test_run_id)
    task = test_run.handler.task
    page_size = task.per_page
    page = task.page
    results = {}
    time = nil
    memory = nil
    values = get_page_values(page, page_size)

    time = Benchmark.measure do
      memory = MemoryProfiler.report do
        results = CalculateStatistics.call(values)
      end
    end

    TestResult.create!(**results, test_run: test_run, duration: time.real, memory_usage: memory.total_allocated_memsize)
  end

  private

  def get_page_values(page, per_page)
    offset = per_page * ((page = page.to_i - 1) < 0 ? 0 : page)

    Sample.limit(per_page).offset(offset).pluck(:value)
  end
end