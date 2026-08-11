# frozen_string_literal: true

module Ticketing
  # An append-only record that a registration submitted one published form
  # version. Its event and ticket scope must match the registration, preventing
  # cross-event answers from being attached as evidence.
  class RegistrationFormSubmission < Ticketing::ApplicationRecord
    self.table_name = "ticketing_registration_form_submissions"

    belongs_to :registration, class_name: "Ticketing::Registration"
    belongs_to :registration_form_version, class_name: "Ticketing::RegistrationFormVersion"
    belongs_to :submitted_by_user, class_name: "Core::User"

    has_many :answers,
             class_name: "Ticketing::RegistrationAnswer",
             dependent: :restrict_with_exception

    validates :submitted_at, presence: true
    validate :event_matches
    validate :product_scope_matches
    validate :published_version
    before_update :prevent_update
    before_destroy :prevent_destroy

    def self.ransackable_attributes(_auth_object = nil)
      %w[id registration_id registration_form_version_id submitted_by_user_id submitted_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[registration registration_form_version submitted_by_user answers]
    end

    private

    def event_matches
      return if registration.blank? || registration_form_version.blank?

      form = registration_form_version.registration_form
      return if form.blank?
      return if registration.event_id.present? && registration.event_id == form.event_id
      return if registration.event == form.event

      errors.add(:registration_form_version, :invalid)
    end

    def product_scope_matches
      return if registration.blank? || registration_form_version.blank?

      form = registration_form_version.registration_form
      return if form.blank? || (form.ticket_type_id.blank? && form.ticket_type.blank?)
      return if form.ticket_type_id.present? && form.ticket_type_id == registration.ticket_type_id
      return if form.ticket_type == registration.ticket_type

      errors.add(:registration_form_version, :invalid)
    end

    def published_version
      return if registration_form_version.blank? || registration_form_version.published?

      errors.add(:registration_form_version, :invalid)
    end

    def prevent_update
      # Answers and their schema snapshots rely on this row as immutable evidence.
      raise ActiveRecord::ReadOnlyRecord, I18n.t("core.errors.immutable_registration_form_submission")
    end

    def prevent_destroy
      raise ActiveRecord::ReadOnlyRecord, I18n.t("core.errors.immutable_registration_form_submission")
    end
  end
end
