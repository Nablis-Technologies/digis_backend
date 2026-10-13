# frozen_string_literal: true

module Marketing
  # Paid, time-bounded discovery entitlement with an immutable offer snapshot.
  class FeaturedPlacement < Marketing::ApplicationRecord
    self.table_name = "marketing_featured_placements"

    STATUSES = %w[pending_payment scheduled active completed cancelled failed].freeze
    SNAPSHOT_ATTRIBUTES = %w[
      event_id organization_id placement_offer_id surface starts_at ends_at duration_seconds offer_code
      offer_version daily_rate_minor amount_minor currency terms_version price_digest request_digest
    ].freeze

    belongs_to :event, class_name: "Events::Event"
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :placement_offer, class_name: "Marketing::PlacementOffer", inverse_of: :featured_placements
    belongs_to :refund, class_name: "Orders::Refund", optional: true

    before_validation :normalize_fields
    validate :event_organization_matches
    validate :price_snapshot_is_consistent
    validate :snapshot_is_immutable, on: :update

    validates :event, :organization, :placement_offer, :status, :surface, :starts_at, :ends_at,
      :duration_seconds, :offer_code, :offer_version, :daily_rate_minor, :amount_minor,
      :currency, :terms_version, :price_digest, :idempotency_key_digest, :request_digest, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :surface, inclusion: { in: PlacementOffer::SURFACES }
    validates :duration_seconds,
      numericality: { only_integer: true, in: PlacementOffer::MINIMUM_DURATION_SECONDS..PlacementOffer::MAXIMUM_DURATION_SECONDS }
    validates :offer_version, numericality: { only_integer: true, greater_than: 0 }
    validates :daily_rate_minor, :amount_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :currency, inclusion: { in: [ PlacementOffer::CURRENCY ] }
    validates :price_digest, :idempotency_key_digest, :request_digest,
      format: { with: /\A[0-9a-f]{64}\z/ }
    validates :failure_code, length: { maximum: 80 }, allow_nil: true

    def serving_at?(at: Time.current)
      status.in?(%w[scheduled active]) && starts_at <= at && ends_at > at
    end

    def refundable_amount_minor(at: Time.current)
      unserved_seconds = [ (ends_at - [ at, starts_at ].max).to_i, 0 ].max
      return 0 unless unserved_seconds.positive?

      amount_minor * unserved_seconds / duration_seconds
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id organization_id placement_offer_id refund_id status surface starts_at ends_at duration_seconds
         offer_code offer_version daily_rate_minor amount_minor currency terms_version price_digest
         idempotency_key_digest request_digest failure_code cancelled_at completed_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event organization placement_offer refund]
    end

    private

    def normalize_fields
      self.status = status.to_s.strip.downcase.presence
      self.surface = surface.to_s.strip.downcase.presence
      self.offer_code = offer_code.to_s.strip.downcase.presence
      self.currency = currency.to_s.strip.upcase.presence
      self.terms_version = terms_version.to_s.strip.presence
      self.price_digest = price_digest.to_s.strip.downcase.presence
      self.idempotency_key_digest = idempotency_key_digest.to_s.strip.downcase.presence
      self.request_digest = request_digest.to_s.strip.downcase.presence
      self.failure_code = failure_code.to_s.strip.presence
    end

    def event_organization_matches
      return if event_id.blank? || organization_id.blank?
      return if Events::Event.where(id: event_id, organization_id:).exists?

      errors.add(:organization_id, :invalid)
    end

    def price_snapshot_is_consistent
      return if amount_minor.blank? || daily_rate_minor.blank? || duration_seconds.blank?
      return if amount_minor == ((daily_rate_minor * duration_seconds + 86_399) / 86_400)

      errors.add(:amount_minor, :invalid)
    end

    def snapshot_is_immutable
      SNAPSHOT_ATTRIBUTES.each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end
  end
end
