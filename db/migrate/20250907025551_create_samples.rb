class CreateSamples < ActiveRecord::Migration[8.0]
  def change
    create_table :samples do |t|
      t.float :value
    end
  end
end
