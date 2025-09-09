class TestRun < ApplicationRecord
  belongs_to :handler
  has_many :test_results
end
