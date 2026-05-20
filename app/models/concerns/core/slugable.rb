module Core
  module Slugable
    extend ActiveSupport::Concern

    class_methods do
      # Note: ensure a unique database index exists on the target column.
      # The in-Ruby uniqueness loop is not sufficient under concurrency.
      def slugable(source: :name, target: :slug, unique: true)
        class_attribute :_slug_source, default: source
        class_attribute :_slug_target, default: target
        class_attribute :_slug_unique, default: unique

        before_validation :_generate_slug, on: :create
        before_validation :_regenerate_slug_if_source_changed, on: :update
        around_create :_retry_on_slug_conflict if unique
      end
    end

    def generate_slug_from_source
      source_value = public_send(self.class._slug_source)
      return if source_value.blank?

      base_slug = source_value.to_s.parameterize
      return base_slug unless self.class._slug_unique

      _unique_slug(base_slug)
    end

    private

    def _generate_slug
      return if public_send(self.class._slug_target).present?

      slug = generate_slug_from_source
      public_send("#{self.class._slug_target}=", slug) if slug.present?
    end

    def _regenerate_slug_if_source_changed
      return unless will_save_change_to_attribute?(self.class._slug_source)

      target_attr = self.class._slug_target
      current_slug = public_send(target_attr)
      return if current_slug.blank?

      old_source_slug = attribute_in_database(self.class._slug_source).to_s.parameterize
      return if old_source_slug.blank?

      auto_generated = current_slug == old_source_slug || current_slug.start_with?("#{old_source_slug}-")
      return unless auto_generated

      slug = generate_slug_from_source
      public_send("#{target_attr}=", slug) if slug.present?
    end

    def _retry_on_slug_conflict
      attempts = 0

      begin
        yield
      rescue ActiveRecord::RecordNotUnique
        attempts += 1
        raise if attempts > 3

        _reset_slug_for_retry
        retry
      end
    end

    def _reset_slug_for_retry
      target_attr = self.class._slug_target
      source_value = public_send(self.class._slug_source)
      base_slug = source_value.to_s.parameterize
      return if base_slug.blank?

      current_slug = public_send(target_attr)
      auto_generated = current_slug.blank? || _auto_generated_slug?(current_slug, base_slug)
      raise ActiveRecord::RecordNotUnique unless auto_generated

      public_send("#{target_attr}=", _unique_slug(base_slug))
    end

    def _auto_generated_slug?(current_slug, base_slug)
      current_slug == base_slug || current_slug.start_with?("#{base_slug}-")
    end

    def _unique_slug(base_slug)
      slug = base_slug
      counter = 1

      loop do
        scope = self.class.where(self.class._slug_target => slug)
        scope = scope.where.not(id: id) if persisted?

        return slug unless scope.exists?

        slug = "#{base_slug}-#{counter}"
        counter += 1
        raise "Could not generate unique slug for #{base_slug}" if counter > 1000
      end
    end
  end
end
