module Platform
  class Review < Platform::ApplicationRecord
    belongs_to :reviewable, polymorphic: true
    belongs_to :reviewed_by, polymorphic: true, optional: true

    validates :context, presence: true
    validates :status, presence: true

    scope :with_context, ->(context_name) { where(context: context_name.to_s) }
    scope :recent_first, -> { order(created_at: :desc) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id context status reviewable_type reviewable_id reviewed_by_type reviewed_by_id reviewed_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[reviewable reviewed_by]
    end

    before_validation :set_default_context
    before_validation :set_default_status

    private

    def set_default_context
      self.context = context.presence || "default"
    end

    def set_default_status
      self.status = status.presence || "draft"
    end
  end
end
