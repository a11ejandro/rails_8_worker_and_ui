class Handler < ApplicationRecord
  TYPES = %w[ruby go python].freeze

  belongs_to :task
  has_many :test_runs, dependent: :destroy
  has_many :test_results, through: :test_runs
  has_many :statistics, dependent: :destroy

  after_save :save_statistics, if: :complete?

  validates :handler_type, presence: true, inclusion: { in: TYPES }

  def duration_statistics
    statistics.find_by(metric: 'duration')
  end

  def memory_statistics
    statistics.find_by(metric: 'memory')
  end

  def complete?
    !test_runs.joins(:test_results).where(test_results: { id: nil }).exists?
  end


  private

  def save_statistics
    if duration_statistics.blank?
      durations = CalculateStatistics.call(test_results.pluck(:duration))
      statistics.create!(**durations, metric: 'duration')
    end

    return if memory_statistics.present?

    memories = CalculateStatistics.call(test_results.pluck(:memory))
    statistics.create!(**memories, metric: 'memory')
  end
end
