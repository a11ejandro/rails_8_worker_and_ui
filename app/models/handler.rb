class Handler < ApplicationRecord
  TYPES = %w[ruby go python].freeze

  validates :type, presence: true, inclusion: { in: TYPES }
end
# type: string