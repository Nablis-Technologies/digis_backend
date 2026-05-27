class AddDeactivatedAtToCoreUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :core_users, :deactivated_at, :datetime
    add_index :core_users, :deactivated_at
    add_column :core_users, :deactivated_reason, :string
  end
end
