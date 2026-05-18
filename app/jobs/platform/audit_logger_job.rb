module Platform
  class AuditLoggerJob < ApplicationJob
    queue_as :audit
    retry_on StandardError, wait: 5.seconds, attempts: 3
    discard_on ActiveRecord::RecordNotFound

    # Handle two signatures for backwards compatibility:
    # 1. Simple mode (legacy): action, audited_changes, metadata
    # 2. Advanced mode: before/after snapshots for change calculation
    def perform(record_id: nil, record_type: nil, before_main: nil, after_main: nil,
                before_associated: {}, after_associated: {}, action_name: nil, controller_name: nil,
                configs: [], actor_id: nil, actor_type: nil, request_uuid: nil, ip_address: nil,
                user_agent: nil, auditable_id: nil, auditable_type: nil, action: nil,
                audited_changes: {}, metadata: {})
      # Support legacy call signature
      if auditable_id.present? && action.present?
        perform_legacy(
          auditable_type: auditable_type,
          auditable_id: auditable_id,
          action: action,
          audited_changes: audited_changes,
          metadata: metadata,
          actor_type: actor_type,
          actor_id: actor_id,
          request_uuid: request_uuid,
          ip_address: ip_address,
          user_agent: user_agent
        )
        return
      end

      # Advanced mode: resolve record and calculate changes
      record = record_type.constantize.find_by(id: record_id)
      return unless record

      actor = actor_id && actor_type ? actor_type.constantize.find_by(id: actor_id) : nil

      all_changes = calculate_changes(
        before_main: before_main,
        after_main: after_main,
        before_associated: before_associated,
        after_associated: after_associated,
        configs: configs
      )

      # Skip if no changes detected
      return if all_changes.blank? ||
                (all_changes.is_a?(Hash) &&
                 all_changes[:main].blank? &&
                 all_changes[:associated].blank?)

      action_label = resolve_action_label(action_name, configs)

      record.record_audit!(
        action_label,
        audited_changes: all_changes,
        metadata: {
          controller: controller_name,
          action: action_name,
          request_uuid: request_uuid
        },
        actor: actor,
        request_uuid: request_uuid,
        ip_address: ip_address,
        user_agent: user_agent
      )
    rescue StandardError => e
      Rails.logger.error "AuditLoggerJob failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      raise
    end

    private

    def perform_legacy(auditable_type:, auditable_id:, action:, audited_changes: {}, metadata: {},
                       actor_type: nil, actor_id: nil, request_uuid: nil, ip_address: nil, user_agent: nil)
      auditable = auditable_type.constantize.find(auditable_id)
      actor = actor_type.present? && actor_id.present? ? actor_type.constantize.find_by(id: actor_id) : nil

      auditable.record_audit!(
        action,
        audited_changes: audited_changes,
        metadata: metadata,
        actor: actor,
        request_uuid: request_uuid,
        ip_address: ip_address,
        user_agent: user_agent
      )
    end

    # Calculate all changes by comparing before/after snapshots
    def calculate_changes(before_main:, after_main:, before_associated:, after_associated:, configs:)
      structured_changes = {
        main: {},
        associated: {}
      }

      configs.each do |config|
        # 1. Main record changes
        main_changes = diff_records(before_main, after_main)
        if main_changes.present?
          filtered = filter_changes(main_changes, config[:only], config[:except])
          if filtered.present?
            structured_changes[:main][:changes] ||= {}
            structured_changes[:main][:changes].merge!(filtered)
          end
        end

        # 2. Associated record changes
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
              id: record_id.to_i,
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

    # Normalize associated config to support both array and hash formats
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

    # Diff two record states (before/after)
    def diff_records(before, after)
      return {} if after.blank?

      if before.blank?
        changes = {}
        after_attrs = after[:attributes] || {}
        after_attrs.each do |key, new_val|
          next if %w[id created_at updated_at].include?(key.to_s)
          next if new_val.nil?

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

        changes[key] = { old: old_val, new: new_val }
      end

      changes
    end

    # Diff associated records (handle create/update/delete)
    def diff_associated_records(before_list, after_list, assoc_name)
      changes = {}

      before_map = before_list.each_with_object({}) { |rec, h| h[rec[:id]] = rec if rec[:id] }
      after_map = after_list.each_with_object({}) { |rec, h| h[rec[:id]] = rec if rec[:id] }

      # Detect created records
      after_map.each do |id, after_rec|
        next if before_map[id]

        created_changes = {}
        (after_rec[:attributes] || {}).each do |key, value|
          next if %w[created_at updated_at].include?(key.to_s)

          created_changes[key] = { old: nil, new: value }
        end

        changes["#{assoc_name}.#{id}"] = {
          action: "created",
          changes: created_changes
        }
      end

      # Detect updated records
      before_map.each do |id, before_rec|
        after_rec = after_map[id]
        next unless after_rec

        record_changes = diff_records(before_rec, after_rec)
        record_changes.reject! { |key, _| %w[created_at updated_at].include?(key.to_s) }
        next unless record_changes.present?

        changes["#{assoc_name}.#{id}"] = {
          action: "updated",
          changes: record_changes
        }
      end

      # Detect deleted records
      before_map.each do |id, before_rec|
        next if after_map[id]

        deleted_changes = {}
        (before_rec[:attributes] || {}).each do |key, value|
          next if %w[created_at updated_at].include?(key.to_s)

          deleted_changes[key] = { old: value, new: nil }
        end

        changes["#{assoc_name}.#{id}"] = {
          action: "deleted",
          changes: deleted_changes
        }
      end

      changes
    end

    # Filter changes based on only/except lists
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

    # Filter associated changes based on per-field only/except
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

    # Resolve action label from config
    def resolve_action_label(action_name, configs)
      configs.each do |config|
        next unless config[:action]

        if config[:action].is_a?(Hash)
          return config[:action][action_name.to_sym] if config[:action][action_name.to_sym]
        elsif config[:action].is_a?(String)
          return config[:action]
        end
      end

      # Default: use action name
      action_name
    end
  end
end
