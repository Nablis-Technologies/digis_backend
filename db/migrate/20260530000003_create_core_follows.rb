class CreateCoreFollows < ActiveRecord::Migration[8.1]
  def change
    create_table :core_follows, id: :uuid do |t|
      t.references :follower, null: false, foreign_key: { to_table: :core_users }, type: :uuid
      t.uuid     :followable_id,   null: false
      t.string   :followable_type, null: false
      t.datetime :followed_at,     null: false
      t.timestamps
    end

    add_index :core_follows, [ :follower_id, :followable_id, :followable_type ], unique: true, name: "index_follows_uniqueness"
    add_index :core_follows, [ :followable_id, :followable_type ], name: "index_follows_followable"
  end
end
