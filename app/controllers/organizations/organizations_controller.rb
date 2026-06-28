module Organizations
  class OrganizationsController < ::Public::ApplicationController
    include Core::PublicCommon

    self.model_class = Organizations::Organization
    self.list_serializer = Organizations::Public::OrganizationListSerializer
    self.detail_serializer = Organizations::Public::OrganizationDetailSerializer

    ATTACHMENT_NAMES = %w[profile banner business_license tin_certificate].freeze

    def index
      records = build_base_scope
      records = apply_catalog_filters(records)
      records = filter_records(records) if searchable?
      records = apply_ordering(records)

      total_count = records.count if paginated_request?
      records = paginated_request? ? apply_pagination(records) : records.limit(default_per_page)
      pagination = paginated_request? ? pagination_metadata(total_count) : nil

      preload_attachments(records)

      render_success(
        data: records,
        serializer_options: { serializer: self.class.list_serializer },
        pagination: pagination
      )
    end

    def show
      record = build_detail_scope.find(params[:id])
      preload_attachments(record)
      render_success(
        data: record,
        serializer_options: { serializer: self.class.detail_serializer }
      )
    end

    private

    def base_scope
      Organizations::Organization.all.with_attached_profile
                   .with_attached_banner.with_attached_business_license
                   .with_attached_tin_certificate
                   .includes(:reviews)
    end

    def detail_scope
      Organizations::Organization.all.with_attached_profile
                   .with_attached_banner.with_attached_business_license
                   .with_attached_tin_certificate
                   .includes(:reviews)
    end

    def searchable?
      true
    end

    def allowed_order_columns
      %w[id name slug created_at]
    end

    def preload_attachments(records)
      ids = Array(records).map(&:id)
      return if ids.empty?

      attachments = ActiveStorage::Attachment.where(
        record_type: "Organizations::Organization",
        record_id: ids
      ).includes(:blob).group_by(&:record_id)

      Array(records).each do |record|
        next unless (org_attachments = attachments[record.id])

        ATTACHMENT_NAMES.each do |name|
          att = org_attachments.find { |a| a.name == name }
          record.association("#{name}_attachment".to_sym).target = att if att
        end
      end
    end
  end
end
