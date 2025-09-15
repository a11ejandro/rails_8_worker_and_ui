class DurationsController < ApplicationController
  def index
    tasks = Task.where(selected: true).includes(handlers: :statistics).order(:id)

    @series_by_handler = {}

    tasks.each do |task|
      per_page = task.respond_to?(:per_page) ? task.per_page : nil
      next unless per_page

      task.handlers.each do |handler|
        stat = handler.duration_statistics
        next unless stat

        @series_by_handler[handler.handler_type] ||= []
        @series_by_handler[handler.handler_type] << {
          x: per_page,
          y: [stat.min, stat.q1, stat.median, stat.q3, stat.max]
        }
      end
    end
  end
end

