class CreateHandlers < ActiveRecord::Migration[8.0]
  def change
    create_table :handlers do |t|
      t.references :task, null: false, foreign_key: true
      t.string :type
    end
  end
end
