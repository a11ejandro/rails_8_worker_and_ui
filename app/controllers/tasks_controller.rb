class TasksController < ApplicationController
  def index
    @tasks = Task.order(created_at: :desc).page(params[:page]).per(20)
  end

  def show
    @task = Task.find(params[:id])
  end

  def enqueue_ruby_runs
    @task = Task.find(params[:id])
    @handler = Handler.create(task: @task, handler_type: 'ruby')
    @task.runs.times do |run|
      test_run = TestRun.create!(handler: @handler, consequent_number: run)
      RubyWorker.perform_async(test_run.id)
    end
    redirect_to task_path(@task), notice: "Enqueued #{@task.runs} Ruby runs."
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

  private

  def task_params
    params.require(:task).permit(:name, :page, :per_page, :runs)
  end
end
