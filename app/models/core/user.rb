module Core
  class User < Core::ApplicationRecord
    include Core::UserAuthenticatable
    include Core::AuditableModel

    has_many :user_roles,
             class_name: "Core::UserRole",
             foreign_key: :user_id,
             dependent: :destroy,
             inverse_of: :user
    has_many :roles,
             through: :user_roles,
             class_name: "Core::Role"
    has_many :reauthentication_proofs,
             class_name: "Core::ReauthenticationProof",
             foreign_key: :user_id,
             dependent: :destroy,
             inverse_of: :user

    has_many :memberships,
             class_name: "Organizations::Membership",
             dependent: :destroy
    has_many :organizations,
             through: :memberships,
             class_name: "Organizations::Organization",
             source: :organization

    has_many :active_follows,
             class_name: "Core::Follow",
             foreign_key: :follower_id,
             dependent: :destroy

    has_many :assigned_user_roles,
             class_name: "Core::UserRole",
             foreign_key: :assigned_by_id,
             dependent: :nullify,
             inverse_of: :assigned_by
    has_many :submitted_reviews,
             class_name: "Core::Review",
             as: :reviewed_by,
             dependent: :nullify
    has_many :event_video_links,
             class_name: "Events::EventVideoLink",
             inverse_of: :created_by
    has_many :event_media,
             class_name: "Events::EventMedia",
             inverse_of: :created_by
    has_many :consent_documents,
             class_name: "Events::ConsentDocument",
             inverse_of: :created_by
    has_many :consent_document_versions,
              class_name: "Events::ConsentDocumentVersion",
              inverse_of: :created_by
    has_many :published_consent_document_versions,
              class_name: "Events::ConsentDocumentVersion",
              inverse_of: :published_by

    has_many :invitations,
              class_name: "Ticketing::Invitation",
              inverse_of: :invited_user,
              foreign_key: :invited_user_id
    has_many :created_invitations,
              class_name: "Ticketing::Invitation",
              inverse_of: :created_by,
              foreign_key: :created_by_id
    has_many :owned_tickets,
             class_name: "Ticketing::Ticket",
             inverse_of: :owner_user,
             foreign_key: :owner_user_id
    has_many :outgoing_ticket_transfers,
             class_name: "Ticketing::TicketTransfer",
             inverse_of: :from_user,
             foreign_key: :from_user_id
    has_many :incoming_ticket_transfers,
             class_name: "Ticketing::TicketTransfer",
             inverse_of: :to_user,
             foreign_key: :to_user_id
    has_many :initiated_ticket_transfers,
             class_name: "Ticketing::TicketTransfer",
             inverse_of: :initiated_by,
             foreign_key: :initiated_by_id
    has_many :stream_sessions,
             class_name: "Ticketing::StreamSession",
             inverse_of: :user,
             dependent: :restrict_with_exception
    has_many :notifications,
             class_name: "Messaging::Notification",
             dependent: :restrict_with_exception,
             inverse_of: :user
    has_many :notification_preferences,
             class_name: "Messaging::NotificationPreference",
             dependent: :destroy,
             inverse_of: :user

    has_many :legal_documents,
             class_name: "Legal::LegalDocument",
             inverse_of: :created_by,
             foreign_key: :created_by_id,
             dependent: :restrict_with_exception
    has_many :legal_document_versions,
             class_name: "Legal::LegalDocumentVersion",
             inverse_of: :created_by,
             foreign_key: :created_by_id,
             dependent: :restrict_with_exception
    has_many :legal_acceptances,
             class_name: "Legal::LegalAcceptance",
             inverse_of: :accepted_by,
             foreign_key: :accepted_by_user_id,
             dependent: :restrict_with_exception
    has_many :published_legal_document_versions,
             class_name: "Legal::LegalDocumentVersion",
             inverse_of: :published_by,
             foreign_key: :published_by_id,
             dependent: :restrict_with_exception

    scope :active, -> { where(deactivated_at: nil) }
    scope :deactivated, -> { where.not(deactivated_at: nil) }

    ROLE_WEIGHT = { "owner" => 3, "admin" => 2, "staff" => 1 }.freeze

    def organizer?
      memberships.active.exists?
    end

    def member_of?(organization)
      memberships.active.where(organization: organization).exists?
    end

    def has_role_in?(organization, *roles)
      memberships.active.where(organization: organization, role: roles).exists?
    end

    def most_privileged_role_in(organization)
      roles = memberships.active.where(organization: organization).pluck(:role)
      return nil if roles.empty?

      roles.max_by { |r| ROLE_WEIGHT[r] || 0 }
    end

    def deactivated?
      deactivated_at.present?
    end

    def deactivation_fraud?
      deactivated_reason == "fraud"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id email phone verified_at deactivated_at deactivated_reason created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[roles]
    end

    def has_role?(role_code)
      active_role_codes.include?(role_code.to_s.upcase)
    end

    def has_permission?(permission_code)
      return true if super_admin?

      active_permissions.include?(permission_code.to_s)
    end

    def has_all_permissions?(*permission_codes)
      permission_codes.flatten.all? { |code| has_permission?(code) }
    end

    def has_any_permission?(*permission_codes)
      permission_codes.flatten.any? { |code| has_permission?(code) }
    end

    def super_admin?
      has_role?("SUPER_ADMIN")
    end

    def active_permissions
      @active_permissions ||= if association(:user_roles).loaded?
        user_roles.select(&:active?)
          .filter_map { |ur| ur.role&.permissions if ur.role&.active? }
          .flatten
          .select(&:active?)
          .map(&:code)
          .uniq
      else
        Core::Permission
          .joins(role_permissions: { role: :user_roles })
          .merge(Core::UserRole.active)
          .where(core_user_roles: { user_id: id })
          .where(core_roles: { active: true }, core_permissions: { active: true })
          .distinct
          .pluck(:code)
      end
    end

    def active_role_codes
      @active_role_codes ||= if association(:user_roles).loaded?
        user_roles.select(&:active?)
          .filter_map { |ur| ur.role&.code if ur.role&.active? }
          .uniq
      else
        roles
          .where(active: true)
          .joins(:user_roles)
          .merge(Core::UserRole.active)
          .where(core_user_roles: { user_id: id })
          .distinct
          .pluck(:code)
      end
    end

    def clear_permission_cache!
      @active_permissions = nil
      @active_role_codes = nil
    end
  end
end
