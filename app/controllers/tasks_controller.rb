class TasksController < ApplicationController
  def index
    @tasks = Task.order(:id)
  end

  def show
    @task = Task.find(params[:id])
    @handler_stats = @task.handlers.includes(test_runs: :test_results).map do |handler|
      {
        handler_type: handler.handler_type,
        duration: handler.duration_statistics,
        memory: handler.memory_statistics
      }
    end
  end

  def enqueue_ruby_runs
    @task = Task.find(params[:id])
    enqueue_runs('ruby') { |id| RubyWorker.perform_async(id) }
    redirect_to task_path(@task), notice: "Enqueued #{@task.runs} Ruby runs."
  end

  def enqueue_go_runs
    @task = Task.find(params[:id])
    enqueue_runs('go') { |id| Sidekiq::Client.push('class' => 'GoWorker', 'queue' => 'go', 'args' => [id]) }
    redirect_to task_path(@task), notice: "Enqueued #{@task.runs} Go runs."
  end

  def new
    @task = Task.new
  end

  def create
    @task = Task.new(task_params)
    if @task.save
      redirect_to tasks_path, notice: 'Task was successfully created.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update_selected
    @task = Task.find(params[:id])
    @task.update!(selected_params)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(helpers.dom_id(@task, :selected), partial: 'tasks/selected_cell', locals: { task: @task })
      end
      format.html { redirect_back fallback_location: tasks_path }
    end
  end

  private

  def task_params
    params.require(:task).permit(:name, :page, :per_page, :runs)
  end

  def selected_params
    params.require(:task).permit(:selected)
  end

  def enqueue_runs(handler_type, &enqueue)
    handler = Handler.create!(task: @task, handler_type: handler_type)
    @task.runs.times do |run|
      test_run = TestRun.create!(handler: handler, consequent_number: run)
      enqueue.call(test_run.id)
    end
  end
end
