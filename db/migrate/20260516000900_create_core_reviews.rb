class CreateCoreReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :core_reviews, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :reviewable, polymorphic: true, null: false, type: :uuid, index: false
      t.string :context, null: false, default: "default"
      t.string :status, null: false, default: "draft"
      t.jsonb :feedback, null: false, default: {}
      t.references :reviewed_by, polymorphic: true, type: :uuid, index: false
      t.datetime :reviewed_at

      t.timestamps
    end

    add_index :core_reviews, %i[reviewable_type reviewable_id context], name: "idx_core_reviews_resource_context"
    add_index :core_reviews, %i[reviewed_by_type reviewed_by_id], name: "idx_core_reviews_reviewer"
    add_index :core_reviews, :status
  end
end
