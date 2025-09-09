class Handler < ApplicationRecord
  TYPES = %w[ruby go python].freeze

  belongs_to :task

  validates :handler_type, presence: true, inclusion: { in: TYPES }
end
# type: string