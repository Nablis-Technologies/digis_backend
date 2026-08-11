class CreateCommercialFeeSchedules < ActiveRecord::Migration[8.1]
  def change
    create_table :commercial_fee_schedules, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :name
      t.timestamps
    end
  end
end
