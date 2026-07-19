# frozen_string_literal: true

module Core
  module Audit
    # Turns controller before/after snapshots into the normalized scalar payload
    # accepted by Core::Audit::Record. All the structural diffing that used to
    # live inside AuditLoggerJob now lives here, so the job is a dumb pipe.
    #
    # Returns success(nil) when the calculated diff is empty (nothing changed),
    # which tells the caller not to enqueue anything.
    class BuildControllerPayload < Core::BaseService
      # Attribute keys whose values must never appear in an audit diff (e.g.
      # password_digest). Dropped from the diff here so automatic CRUD audits
      # of user/account records don't leak secrets — they are omitted, not raised.
      SENSITIVE_KEY_PATTERNS = [
        /password/i,
        /(^|_)token($|_)/i,
        /secret/i,
        /ciphertext/i,
        /(^|_)qr($|_)/i,
        /(^|_)pnr($|_)/i,
        /lookup_code/i,
        /account_number/i,
        /provider_payload/i,
        /webhook_body/i,
        /answer/i,
        /consent_content/i,
        /encrypted/i
      ].freeze
      def initialize(record_id:, record_type:, before_main:, after_main:,
        before_associated: {}, after_associated: {}, action_name:, controller_name:,
        configs:, actor_id:, actor_type:, request_uuid:, ip_address:, user_agent:)
        @record_id = record_id
        @record_type = record_type
        @before_main = before_main
        @after_main = after_main
        @before_associated = before_associated || {}
        @after_associated = after_associated || {}
        @action_name = action_name
        @controller_name = controller_name
        @configs = configs || []
        @actor_id = actor_id
        @actor_type = actor_type
        @request_uuid = request_uuid
        @ip_address = ip_address
        @user_agent = user_agent
      end

      def call
        all_changes = calculate_changes(
          before_main: @before_main,
          after_main: @after_main,
          before_associated: @before_associated,
          after_associated: @after_associated,
          configs: @configs
        )

        # Nothing changed: signal the caller to skip enqueue entirely.
        return success(nil) if all_changes.blank? ||
          (all_changes.is_a?(Hash) && all_changes[:main].blank? && all_changes[:associated].blank?)

        action_label = resolve_action_label(@action_name, @configs)
        audit_key = "controller:#{@request_uuid}:#{@record_type}:#{@record_id}:#{action_label}"

        success(
          audit_key: audit_key,
          action: action_label,
          auditable_type: @record_type,
          auditable_id: @record_id,
          actor_type: @actor_type,
          actor_id: @actor_id,
          audited_changes: all_changes,
          metadata: {
            controller: @controller_name,
            action: @action_name,
            request_uuid: @request_uuid
          },
          request_uuid: @request_uuid,
          ip_address: @ip_address,
          user_agent: @user_agent
        )
      end

      private

      def calculate_changes(before_main:, after_main:, before_associated:, after_associated:, configs:)
        structured_changes = { main: {}, associated: {} }

        configs.each do |config|
          main_changes = diff_records(before_main, after_main)
          if main_changes.present?
            filtered = filter_changes(main_changes, config[:only], config[:except])
            if filtered.present?
              structured_changes[:main][:changes] ||= {}
              structured_changes[:main][:changes].merge!(filtered)
            end
          end

          associations_config = normalize_associated_config(config[:associated])

          associations_config.each do |assoc_name, assoc_options|
            assoc_key = assoc_name.to_sym
            before_assoc = before_associated[assoc_key] || []
            after_assoc = after_associated[assoc_key] || []

            assoc_changes = diff_associated_records(before_assoc, after_assoc, assoc_name)
            next unless assoc_changes.present?

            assoc_only = assoc_options[:only]
            assoc_except = assoc_options[:except]
            filtered_assoc_changes = filter_associated_changes(assoc_changes, assoc_only, assoc_except)
            next unless filtered_assoc_changes.present?

            structured_changes[:associated][assoc_name.to_s] ||= []

            filtered_assoc_changes.each do |key, value|
              record_id = key.to_s.split(".").last
              model_name = after_assoc.find { |r| r[:id].to_s == record_id }&.dig(:type) ||
                before_assoc.find { |r| r[:id].to_s == record_id }&.dig(:type) ||
                assoc_name.to_s.singularize.camelize

              structured_changes[:associated][assoc_name.to_s] << {
                id: record_id,
                action: value[:action] || value["action"],
                model: model_name,
                changes: value[:changes] || value["changes"] || {}
              }
            end
          end
        end

        return {} if structured_changes[:main].empty? && structured_changes[:associated].empty?

        structured_changes
      end

      # Supports both array (no filters) and hash (per-association only/except)
      # association config shapes.
      def normalize_associated_config(associated)
        return {} if associated.blank?

        if associated.is_a?(Array)
          associated.each_with_object({}) { |name, h| h[name] = { only: nil, except: nil } }
        elsif associated.is_a?(Hash)
          associated.transform_values do |value|
            if value.is_a?(Hash)
              { only: value[:only], except: value[:except] }
            else
              { only: nil, except: nil }
            end
          end
        else
          {}
        end
      end

      def diff_records(before, after)
        if before.present? && after.blank?
          changes = {}
          before_attrs = before[:attributes] || {}
          before_attrs.each do |key, old_val|
            next if %w[id created_at updated_at].include?(key.to_s)
            next if old_val.nil?
            next if sensitive_key?(key)

            changes[key] = { old: old_val, new: nil }
          end
          return changes
        end

        return {} if after.blank?

        if before.blank?
          changes = {}
          after_attrs = after[:attributes] || {}
          after_attrs.each do |key, new_val|
            next if %w[id created_at updated_at].include?(key.to_s)
            next if new_val.nil?
            next if sensitive_key?(key)

            changes[key] = { old: nil, new: new_val }
          end
          return changes
        end

        return {} if before[:id] != after[:id]

        changes = {}
        before_attrs = before[:attributes] || {}
        after_attrs = after[:attributes] || {}

        all_keys = (before_attrs.keys + after_attrs.keys).uniq
        all_keys.each do |key|
          old_val = before_attrs[key]
          new_val = after_attrs[key]

          next if old_val == new_val
          next if sensitive_key?(key)

          changes[key] = { old: old_val, new: new_val }
        end

        changes
      end

      def sensitive_key?(key)
        SENSITIVE_KEY_PATTERNS.any? { |pattern| pattern.match?(key.to_s) }
      end

      def diff_associated_records(before_list, after_list, assoc_name)
        changes = {}

        before_map = before_list.each_with_object({}) { |rec, h| h[rec[:id]] = rec if rec[:id] }
        after_map = after_list.each_with_object({}) { |rec, h| h[rec[:id]] = rec if rec[:id] }

        after_map.each do |id, after_rec|
          next if before_map[id]

          created_changes = {}
          (after_rec[:attributes] || {}).each do |key, value|
            next if %w[created_at updated_at].include?(key.to_s)

            created_changes[key] = { old: nil, new: value }
          end

          changes["#{assoc_name}.#{id}"] = { action: "created", changes: created_changes }
        end

        before_map.each do |id, before_rec|
          after_rec = after_map[id]
          next unless after_rec

          record_changes = diff_records(before_rec, after_rec)
          record_changes.reject! { |key, _| %w[created_at updated_at].include?(key.to_s) }
          next unless record_changes.present?

          changes["#{assoc_name}.#{id}"] = { action: "updated", changes: record_changes }
        end

        before_map.each do |id, before_rec|
          next if after_map[id]

          deleted_changes = {}
          (before_rec[:attributes] || {}).each do |key, value|
            next if %w[created_at updated_at].include?(key.to_s)

            deleted_changes[key] = { old: value, new: nil }
          end

          changes["#{assoc_name}.#{id}"] = { action: "deleted", changes: deleted_changes }
        end

        changes
      end

      def filter_changes(changes, only_list, except_list)
        return changes if only_list.blank? && except_list.blank?

        only_arr = Array(only_list).map(&:to_s)
        except_arr = Array(except_list).map(&:to_s)

        changes.select do |key, _|
          key_str = key.to_s
          if only_arr.any?
            only_arr.include?(key_str)
          elsif except_arr.any?
            !except_arr.include?(key_str)
          else
            true
          end
        end
      end

      def filter_associated_changes(changes, only_list, except_list)
        return changes if only_list.blank? && except_list.blank?

        only_arr = Array(only_list).map(&:to_s)
        except_arr = Array(except_list).map(&:to_s)

        changes.each do |key, change_data|
          next unless change_data.is_a?(Hash) && change_data[:changes]

          filtered_fields = filter_changes(change_data[:changes], only_arr, except_arr)
          change_data[:changes] = filtered_fields
        end

        changes.reject { |_, change_data| change_data[:changes].blank? }
      end

      def resolve_action_label(action_name, configs)
        configs.each do |config|
          next unless config[:action]

          if config[:action].is_a?(Hash)
            return config[:action][action_name.to_sym] if config[:action][action_name.to_sym]
          elsif config[:action].is_a?(String)
            return config[:action]
          end
        end

        action_name
      end
    end
  end
end
