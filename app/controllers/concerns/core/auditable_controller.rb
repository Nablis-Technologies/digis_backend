# frozen_string_literal: true

module Core
  module AuditableController
    extend ActiveSupport::Concern

    included do
      class_attribute :_audit_configs, default: []
      class_attribute :_explicit_auditable_model, default: nil

      before_action :capture_audit_snapshot, if: :audit_needed?
      after_action :enqueue_audit, if: :audit_needed?
    end

    class_methods do
      # DSL: Define what to audit
      #
      # Simple format (backwards compatible):
      #   auditable associated: [:comments], only: [:status], on: [:approve, :reject]
      #   auditable only: [:name, :email], on: [:create, :update]
      #
      # Advanced format with per-association filters:
      #   auditable on: [:create, :update],
      #             only: [:status, :approved_at],          # filter for main record
      #             except: [:internal_notes],              # exclude for main record
      #             associated: {
      #               comments: { only: [:status, :approved_at] },  # filter for comments
      #               attachments: { except: [:private_flag] }      # exclude for attachments
      #             }
      def auditable(associated: [], only: [], except: [], on: [], action: nil, required: true)
        validate_audit_config!(associated: associated, only: only, except: except, on: on, action: action)

        normalized_associated = normalize_associated_for_config(associated)

        config = {
          associated: normalized_associated,
          only: Array(only),
          except: Array(except),
          on: Array(on).map(&:to_sym),
          action: action,
          required: required
        }
        self._audit_configs += [ config ]
      end

      # Validate audit configuration at definition time
      def validate_audit_config!(associated:, only:, except:, on:, action:)
        if associated.is_a?(Array)
          Array(associated).each do |assoc|
            unless assoc.is_a?(Symbol)
              raise ArgumentError, I18n.t(
                "core.errors.unsupported_auditable_associated",
                type: assoc.class,
                value: assoc.inspect
              )
            end
          end
        elsif associated.is_a?(Hash)
          associated.each do |assoc_name, assoc_config|
            unless assoc_name.is_a?(Symbol)
              raise ArgumentError, I18n.t(
                "core.errors.auditable_associated_keys",
                type: assoc_name.class
              )
            end

            if assoc_config.present? && !assoc_config.is_a?(Hash)
              raise ArgumentError, I18n.t(
                "core.errors.auditable_associated_values",
                type: assoc_config.class
              )
            end

            next unless assoc_config.is_a?(Hash)

            assoc_only = Array(assoc_config[:only])
            assoc_except = Array(assoc_config[:except])
            overlap = assoc_only & assoc_except
            if overlap.any?
              Rails.logger.warn "⚠️  Auditable config warning: 'only' and 'except' overlap for #{assoc_name}: " \
                                "#{overlap.join(', ')}. 'except' will take precedence."
            end
          end
        end

        only_arr = Array(only).map(&:to_sym)
        except_arr = Array(except).map(&:to_sym)
        overlap = only_arr & except_arr
        if overlap.any?
          Rails.logger.warn "⚠️  Auditable config warning: 'only' and 'except' overlap for fields: " \
                            "#{overlap.join(', ')}. 'except' will take precedence."
        end

        if action.present?
          unless action.is_a?(String) || action.is_a?(Hash)
            raise ArgumentError, I18n.t("core.errors.auditable_action_type", type: action.class)
          end

          if action.is_a?(Hash)
            action.each do |key, value|
              unless key.is_a?(Symbol) && value.is_a?(String)
                raise ArgumentError, I18n.t("core.errors.auditable_action_values")
              end
            end
          end
        end

        on_arr = Array(on).map(&:to_sym)
        valid_actions = %i[index show create update destroy approve reject request_modification resubmit submit]
        invalid_actions = on_arr - valid_actions
        return unless invalid_actions.any? && !Rails.env.production?

        Rails.logger.warn "⚠️  Auditable config warning: Unknown actions detected: #{invalid_actions.join(', ')}. " \
                          "Make sure these are valid controller actions."
      end

      # DSL: Explicitly set the model class (optional)
      def auditable_model(klass)
        self._explicit_auditable_model = klass
      end

      # DSL: Define action-specific record resolution (optional)
      def auditable_record_for(action_name, resolver = nil, &block)
        self._audit_configs ||= []
        resolver_proc = block || resolver

        raise ArgumentError, I18n.t("core.errors.auditable_record_resolver") unless resolver_proc

        @_auditable_record_resolvers ||= {}
        @_auditable_record_resolvers[action_name.to_sym] = resolver_proc
      end

      def auditable_record_resolvers
        @_auditable_record_resolvers || {}
      end

      private

      def normalize_associated_for_config(associated)
        return {} if associated.blank?

        if associated.is_a?(Array)
          associated.each_with_object({}) { |name, h| h[name] = {} }
        elsif associated.is_a?(Hash)
          associated
        else
          {}
        end
      end
    end

    private

    # Check if current action needs auditing
    def audit_needed?
      return false if _audit_configs.empty?

      _audit_configs.any? { |c| c[:on].empty? || c[:on].include?(action_name.to_sym) }
    end

    # Step 1: Capture state BEFORE action executes
    def capture_audit_snapshot
      @audit_snapshot = {}

      if action_name.to_sym == :create
        @audit_snapshot[:is_create] = true
        @audit_snapshot[:before_main] = nil
        @audit_snapshot[:before_associated] = {}
        Rails.logger.debug "Audit: Create action detected, will capture state after creation"
        return
      end

      record = resolve_auditable_record
      return unless record

      @audit_snapshot[:record_id] = record.id
      @audit_snapshot[:record_type] = record.class.name
      @audit_snapshot[:before_main] = capture_record_state(record)

      @audit_snapshot[:before_associated] = {}
      active_configs.each do |config|
        assoc_names = config[:associated].is_a?(Hash) ? config[:associated].keys : config[:associated]
        assoc_names.each do |assoc_name|
          next unless record.respond_to?(assoc_name)

          begin
            assoc_records = Array(record.public_send(assoc_name)).compact
            @audit_snapshot[:before_associated][assoc_name] = assoc_records.map { |r| capture_record_state(r) }
          rescue StandardError => e
            Rails.logger.debug "Audit: Could not capture #{assoc_name}: #{e.message}"
          end
        end
      end

      remove_instance_variable(:@resolve_auditable_record) if defined?(@resolve_auditable_record)
    rescue StandardError => e
      Rails.logger.warn "Audit snapshot failed: #{e.message}"
      @audit_snapshot = nil
    end

    # Step 2: Enqueue audit job AFTER action completes
    def enqueue_audit
      Rails.logger.debug "Audit: enqueue_audit called for #{action_name}"

      unless @audit_snapshot.present?
        Rails.logger.debug "Audit: No snapshot present, skipping"
        return
      end

      if @audit_snapshot[:is_create]
        model_klass = _explicit_auditable_model || detect_model_class
        record = find_created_record_quietly(model_klass)

        if record.nil? || !record.persisted?
          Rails.logger.debug "Audit: Skipping failed create (record not persisted)"
          return
        end

        @audit_snapshot[:record_id] = record.id
        @audit_snapshot[:record_type] = record.class.name
        Rails.logger.debug "Audit: Set record info for create action"
      end

      record = resolve_auditable_record

      unless record
        if action_name.to_sym == :destroy && @audit_snapshot[:record_id].present?
          Rails.logger.debug "Audit: Record destroyed, using snapshot data for destroy audit"
          enqueue_audit_job(
            record_id: @audit_snapshot[:record_id],
            record_type: @audit_snapshot[:record_type],
            before_main: @audit_snapshot[:before_main],
            after_main: nil,
            before_associated: @audit_snapshot[:before_associated] || {},
            after_associated: {}
          )
          return
        end

        log_resolution_failure(detect_model_class, action_name.to_sym)
        return
      end

      Rails.logger.debug "Audit: Found record #{record.class.name}##{record.id}"

      after_main = capture_record_state(record)
      after_associated = {}

      active_configs.each do |config|
        assoc_names = config[:associated].is_a?(Hash) ? config[:associated].keys : config[:associated]
        assoc_names.each do |assoc_name|
          next unless record.respond_to?(assoc_name)

          begin
            record.association(assoc_name).reload if record.association(assoc_name).loaded?
            assoc_records = Array(record.public_send(assoc_name)).compact
            after_associated[assoc_name] = assoc_records.map { |r| capture_record_state(r) }
            Rails.logger.debug "Audit: Captured #{assoc_records.count} #{assoc_name} records"
          rescue StandardError => e
            Rails.logger.debug "Audit: Could not capture after state for #{assoc_name}: #{e.message}"
          end
        end
      end

      enqueue_audit_job(
        record_id: @audit_snapshot[:record_id],
        record_type: @audit_snapshot[:record_type],
        before_main: @audit_snapshot[:before_main],
        after_main: after_main,
        before_associated: @audit_snapshot[:before_associated] || {},
        after_associated: after_associated
      )
    end

    # Build a normalized audit payload and enqueue it. The builder collapses
    # no-op diffs to nil (skip), and the job is a dumb pipe into Core::Audit::Record.
    def enqueue_audit_job(record_id:, record_type:, before_main:, after_main:, before_associated:, after_associated:)
      required = active_configs.any? { |c| c[:required] != false }

      result = Core::Audit::BuildControllerPayload.call(
        record_id: record_id,
        record_type: record_type,
        before_main: before_main,
        after_main: after_main,
        before_associated: before_associated,
        after_associated: after_associated,
        actor_id: current_actor&.id,
        actor_type: current_actor&.class&.name,
        action_name: action_name,
        controller_name: controller_name,
        request_uuid: request.uuid,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        configs: active_configs.map { |c| c.except(:block) }
      )

      # No diff -> nothing to record.
      return unless result.success? && result.value

      begin
        Core::AuditLoggerJob.perform_later(**result.value)
        Rails.logger.debug "Audit: Job enqueued successfully"
      rescue StandardError => e
        Rails.logger.error "CRITICAL: Audit enqueue failed: #{e.message}"
        raise Core::AuditableRecordNotFoundError,
              I18n.t("core.errors.audit_enqueue_failed") if required
      end
    rescue Core::AuditableRecordNotFoundError
      raise
    rescue StandardError => e
      Rails.logger.error "Audit enqueue failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      raise Core::AuditableRecordNotFoundError,
            I18n.t("core.errors.audit_enqueue_unexpected") if required
    end

    # Capture complete state of a record
    def capture_record_state(record)
      return nil unless record&.persisted?

      {
        id: record.id,
        type: record.class.name,
        attributes: record.attributes.dup,
        timestamp: Time.current.to_f
      }
    rescue StandardError => e
      Rails.logger.debug "Could not capture record state: #{e.message}"
      nil
    end

    # Get active audit configs for current action
    def active_configs
      _audit_configs.select { |c| c[:on].empty? || c[:on].include?(action_name.to_sym) }
    end

    # Resolve the main record being audited
    def resolve_auditable_record
      return @resolve_auditable_record if defined?(@resolve_auditable_record)

      @resolve_auditable_record = perform_record_resolution
    end

    # Perform the actual record resolution logic
    def perform_record_resolution
      model_klass = _explicit_auditable_model || detect_model_class
      return nil unless model_klass.respond_to?(:ancestors) && model_klass.ancestors.include?(ActiveRecord::Base)

      current_action = action_name.to_sym

      # Priority 0: Action-specific resolver (explicit configuration via DSL)
      resolver = self.class.auditable_record_resolvers[current_action]
      if resolver
        begin
          record = instance_exec(&resolver)
          if record.is_a?(model_klass)
            Rails.logger.debug "Audit: Found record via action-specific resolver for :#{current_action}"
            return record
          elsif record.present?
            Rails.logger.warn "Audit: Action-specific resolver for :#{current_action} returned " \
                              "#{record.class.name}, expected #{model_klass.name}"
          end
        rescue StandardError => e
          Rails.logger.error "Audit: Action-specific resolver for :#{current_action} failed: #{e.message}"
        end
      end

      # Priority 1: Instance method map (auditable_record_map)
      if respond_to?(:auditable_record_map, true)
        begin
          record_map = auditable_record_map
          if record_map.is_a?(Hash) && record_map[current_action]
            resolver_proc = record_map[current_action]
            record = instance_exec(&resolver_proc)
            if record.is_a?(model_klass)
              Rails.logger.debug "Audit: Found record via auditable_record_map for :#{current_action}"
              return record
            end
          end
        rescue StandardError => e
          Rails.logger.warn "Audit: auditable_record_map failed for :#{current_action}: #{e.message}"
        end
      end

      # Priority 2: Generic hook method (auditable_record)
      if respond_to?(:auditable_record, true)
        record = auditable_record
        if record.is_a?(model_klass)
          Rails.logger.debug "Audit: Found record via auditable_record hook"
          return record
        end
      end

      # Priority 3: Check ALL instance variables for objects of the model class
      instance_variables.each do |ivar|
        next if ivar.to_s.start_with?("@__", "@audit")
        next if ivar == :@current_user

        obj = instance_variable_get(ivar)
        if obj.is_a?(model_klass)
          Rails.logger.debug "Audit: Found record via instance variable #{ivar}"
          return obj
        end
      end

      # Priority 4: Try standard Rails @model_name pattern (e.g., @event)
      ivar_name = "@#{model_klass.name.demodulize.underscore}"
      if instance_variable_defined?(ivar_name)
        obj = instance_variable_get(ivar_name)
        if obj.is_a?(model_klass)
          Rails.logger.debug "Audit: Found record via naming convention #{ivar_name}"
          return obj
        end
      end

      # Priority 5: Try finding by params[:id] (for show/update/delete actions)
      if params[:id].present? && current_action != :create
        begin
          record = model_klass.find(params[:id])
          Rails.logger.debug "Audit: Found record via params[:id]"
          return record
        rescue ActiveRecord::RecordNotFound, ArgumentError
          # Record not found or invalid ID
        end
      end

      log_resolution_failure(model_klass, current_action)
      nil
    rescue StandardError => e
      Rails.logger.error "Audit: Failed to resolve record for #{model_klass}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      nil
    end

    # Handle missing auditable record with environment-aware fail-fast behavior
    def log_resolution_failure(model_class, action)
      instance_vars_info = instance_variables.filter_map do |v|
        obj = instance_variable_get(v)
        "  - #{v} (#{obj.class.name})"
      rescue StandardError
        nil
      end.join("\n")

      detailed_message = <<~ERROR
        ═══════════════════════════════════════════════════════════════════════════
        🚨 AUDITABLE SYSTEM ERROR: Could not resolve record for audit logging
        ═══════════════════════════════════════════════════════════════════════════

        Controller: #{self.class.name}
        Action: #{action}
        Model: #{model_class.name}

        The Auditable system tried to find the #{model_class.name} record but failed.

        💡 SOLUTION: Define an action-specific resolver in your controller:

        Option 1 - Using auditable_record_map (recommended for multiple actions):
        ─────────────────────────────────────────────────────────────────────────
        private

        def auditable_record_map
          {
            #{action}: -> { @your_instance_variable }
          }
        end

        Option 2 - Using class-level DSL:
        ─────────────────────────────────────────────────────────────────────────
        auditable_record_for :#{action}, -> { @your_instance_variable }

        Option 3 - Using a generic hook (for all actions):
        ─────────────────────────────────────────────────────────────────────────
        private

        def auditable_record
          @your_instance_variable
        end

        📋 Available instance variables in controller:
        #{instance_vars_info.presence || '  (none found)'}

        ═══════════════════════════════════════════════════════════════════════════
      ERROR

      Rails.logger.error(detailed_message)

      raise Core::AuditableRecordNotFoundError, detailed_message unless Rails.env.production?

      Rails.logger.error("[CRITICAL] Audit system failed to resolve #{model_class.name} for action :#{action} in #{self.class.name}")

       raise Core::AuditableRecordNotFoundError,
             I18n.t(
               "core.errors.auditable_record_unresolved",
               model: model_class.name,
               action:
             )
    end

    # Find created record without triggering error logging
    def find_created_record_quietly(model_klass)
      return nil unless model_klass.respond_to?(:ancestors) && model_klass.ancestors.include?(ActiveRecord::Base)

      candidates = []

      instance_variables.each do |ivar|
        next if ivar.to_s.start_with?("@__", "@audit")

        obj = instance_variable_get(ivar)
        candidates << obj if obj.is_a?(model_klass)
      end

      ivar_name = "@#{model_klass.name.demodulize.underscore}"
      if instance_variable_defined?(ivar_name)
        obj = instance_variable_get(ivar_name)
        candidates << obj if obj.is_a?(model_klass)
      end

      return candidates.first if candidates.one?

      actor = current_actor rescue nil
      candidates.find { |c| actor.nil? || c != actor } || candidates.first
    rescue StandardError => e
      Rails.logger.debug "Audit: Could not quietly find created record: #{e.message}"
      nil
    end

    # Auto-detect model class from controller name
    def detect_model_class
      if self.class.respond_to?(:model_class) && self.class.model_class.present?
        return self.class.model_class
      end

      model_name = controller_name.classify
      namespace = self.class.name.deconstantize

      if namespace.present? && namespace != "Object"
        "#{namespace}::#{model_name}".safe_constantize
      else
        model_name.safe_constantize
      end
    end

    # Get current actor (user performing the action)
    def current_actor
      return @current_actor if defined?(@current_actor)

      @current_actor = current_user if respond_to?(:current_user, true)
    end
  end
end
