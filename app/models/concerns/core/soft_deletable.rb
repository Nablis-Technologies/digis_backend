module Core
  module SoftDeletable
    extend ActiveSupport::Concern

    included do
      scope :kept, -> { where(deleted_at: nil) }
      scope :only_deleted, -> { where.not(deleted_at: nil) }
      scope :with_deleted, -> { all }
    end

    def soft_delete!
      update!(deleted_at: Time.current)
    end

    def restore!
      update!(deleted_at: nil)
    end

    def deleted?
      deleted_at.present?
    end
  end
end
