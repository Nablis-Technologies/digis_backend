# frozen_string_literal: true

module Ticketing
  class Registration < Ticketing::ApplicationRecord
    self.table_name = "ticketing_registrations"

    SOURCES = %w[self_service organizer_complimentary walk_up].freeze
    STATUSES = %w[
      pending_payment pending_approval waitlisted offered confirmed rejected cancelled expired
    ].freeze
    COMPLIMENTARY_REASONS = %w[
      accessibility accommodation community_partner service_recovery sponsor_guest staff_guest
    ].freeze

    belongs_to :event, class_name: "Events::Event"
    belongs_to :ticket_type, class_name: "Ticketing::TicketType"
    belongs_to :user, class_name: "Core::User"
    belongs_to :selected_event_date, class_name: "Events::EventDate", optional: true
    belongs_to :access_code, class_name: "Ticketing::AccessCode", optional: true
    belongs_to :invitation, class_name: "Ticketing::Invitation", optional: true
    belongs_to :created_by, class_name: "Core::User"
    belongs_to :reviewed_by, class_name: "Core::User", optional: true

    has_many :form_submissions,
             class_name: "Ticketing::RegistrationFormSubmission",
             dependent: :restrict_with_exception
    has_many :retention_holds,
             class_name: "Core::DataRetentionHold",
             dependent: :restrict_with_exception

    validates :source, presence: true, inclusion: { in: SOURCES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :identity_digest, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
    validates :package_quantity, :admissions_per_unit_snapshot, :party_size,
              numericality: { only_integer: true, greater_than: 0 }
    validates :submitted_at, presence: true
    validates :issuance_idempotency_key, uniqueness: true, allow_blank: true

    validate :source_metadata
    validate :party_size_matches_snapshot
    validate :ticket_type_belongs_to_event
    validate :selected_date_belongs_to_event
    validate :selected_date_matches_ticket_type
    validate :status_timestamps
    validate :source_immutable
    validate :scope_immutable_after_submission

    scope :active, -> { where(status: %w[pending_payment pending_approval waitlisted offered confirmed]) }
    scope :for_event, ->(event) { where(event_id: event.id) }

    def pending_payment?
      status == "pending_payment"
    end

    def confirmed?
      status == "confirmed"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_id ticket_type_id user_id selected_event_date_id access_code_id invitation_id
        source created_by_id issuance_idempotency_key complimentary_reason identity_digest
        package_quantity admissions_per_unit_snapshot party_size status submitted_at waitlisted_at
        offered_at offer_expires_at reviewed_by_id approved_at rejected_at confirmed_at cancelled_at
        lock_version created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event ticket_type user selected_event_date access_code invitation created_by reviewed_by]
    end

    private

    def source_metadata
      if source == "organizer_complimentary"
        errors.add(:complimentary_reason, :blank) if complimentary_reason.blank?
        errors.add(:complimentary_reason, :inclusion) unless COMPLIMENTARY_REASONS.include?(complimentary_reason)
        errors.add(:issuance_idempotency_key, :blank) if issuance_idempotency_key.blank?
      elsif complimentary_reason.present?
        errors.add(:complimentary_reason, :invalid)
      end
    end

    def party_size_matches_snapshot
      return if package_quantity.blank? || admissions_per_unit_snapshot.blank? || party_size.blank?
      return if party_size == package_quantity * admissions_per_unit_snapshot

      errors.add(:party_size, :invalid)
    end

    def ticket_type_belongs_to_event
      return if event.blank? || ticket_type.blank?

      event_product = ticket_type.event_product
      return if event_product&.event_id == event_id
      return if event_product&.event == event

      errors.add(:ticket_type, :invalid)
    end

    def selected_date_belongs_to_event
      return if selected_event_date.blank? || event.blank?
      return if selected_event_date.event_id == event_id
      return if selected_event_date.event == event

      errors.add(:selected_event_date, :invalid)
    end

    def selected_date_matches_ticket_type
      return if ticket_type.blank?

      if ticket_type.date_selection == "choose_one" && selected_event_date.blank?
        errors.add(:selected_event_date, :blank)
      elsif ticket_type.date_selection == "fixed" && selected_event_date.present?
        errors.add(:selected_event_date, :invalid)
      end
      return if selected_event_date.blank?
      if selected_event_date.status == "cancelled"
        errors.add(:selected_event_date, :invalid)
        return
      end

      return unless ticket_type.date_selection == "choose_one"

      accesses = ticket_type.event_product&.product_accesses
      return if accesses&.any? { |access| access.event_date_id == selected_event_date.id }

      errors.add(:selected_event_date, :invalid)
    end

    def status_timestamps
      if status == "waitlisted" && waitlisted_at.blank?
        errors.add(:waitlisted_at, :blank)
      elsif status != "waitlisted" && waitlisted_at.present?
        errors.add(:waitlisted_at, :invalid)
      end

      if status == "offered"
        return if offered_at.present? && offer_expires_at.present? && offer_expires_at > offered_at

        errors.add(:offer_expires_at, :invalid)
      elsif offered_at.present? || offer_expires_at.present?
        errors.add(:offered_at, :invalid)
      end
    end

    def source_immutable
      return unless persisted? && will_save_change_to_source? && submitted_at_in_database.present?

      errors.add(:source, :immutable)
    end

    def scope_immutable_after_submission
      changed_fields = %i[
        event_id ticket_type_id selected_event_date_id package_quantity
        admissions_per_unit_snapshot party_size
      ].select { |field| public_send("will_save_change_to_#{field}?") }
      return if changed_fields.empty?
      return unless persisted?
      return unless form_submissions.exists?

      changed_fields.each { |field| errors.add(field, :immutable) }
    end
  end
end
