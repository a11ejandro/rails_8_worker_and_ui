class CreateTasks < ActiveRecord::Migration[8.0]
  def change
    create_table :tasks do |t|
      t.string :name
      t.integer :page
      t.integer :per_page
      t.integer :runs
      t.timestamps
    end
  end
end
