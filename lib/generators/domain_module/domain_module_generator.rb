class DomainModuleGenerator < Rails::Generators::NamedBase
  source_root File.expand_path("templates", __dir__)

  Column = Struct.new(:name, :type, :class_name) do
    def belongs_to?
      type == :belongs_to
    end

    def sample_value
      case type
      when :string    then "\"Sample #{name.humanize}\""
      when :text      then "\"Sample text for #{name.humanize}\""
      when :integer   then "1"
      when :decimal, :float then "1.0"
      when :boolean   then "true"
      when :date      then "Date.current"
      when :datetime  then "Time.current"
      when :jsonb     then "{}"
      end
    end

    def sample_update_value
      case type
      when :string    then "\"Updated #{name.humanize}\""
      when :text      then "\"Updated text for #{name.humanize}\""
      when :integer   then "2"
      when :decimal, :float then "2.0"
      when :boolean   then "false"
      when :date      then "Date.yesterday"
      when :datetime  then "1.day.ago"
      when :jsonb     then "{ updated: true }"
      end
    end
  end

  VALID_COMPONENTS = %w[
    migration model controller serializer policy locale
    fixture integration_test route
  ].freeze

  class_option :auditable, type: :boolean, default: false
  class_option :slug, type: :boolean, default: false
  class_option :slug_source, type: :string, default: nil
  class_option :skip_migration, type: :boolean, default: false
  class_option :skip_routes, type: :boolean, default: false
  class_option :skip_tests, type: :boolean, default: false
  class_option :interactive, type: :boolean, default: true
  class_option :only, type: :array, default: nil,
    desc: "Only generate these components (#{VALID_COMPONENTS.join(', ')})"
  class_option :skip, type: :array, default: nil,
    desc: "Skip these components (#{VALID_COMPONENTS.join(', ')})"

  COLUMN_RE = /\A
    (\w+)                     # name
    :
    (string|text|integer|decimal|float|boolean|date|datetime|jsonb|belongs_to)
    (?:\[(\w+(?:::\w+)*)\])?  # optional bracketed class_name for belongs_to
  \z/x

  def initialize(*)
    super
    return unless behavior == :invoke
    validate_options!
    resolve_interactive_options if interactive?
  end

  def create_migration_file
    return unless component_enabled?(:migration)
    return if options[:skip_migration]
    template "migration.rb.tt", "db/migrate/#{timestamp}_create_#{table_name}.rb"
  end

  def create_application_record_file
    return if namespace_base_classes_exist?
    template "application_record.rb.tt", "app/models/#{namespace_path}/application_record.rb"
  end

  def create_model_file
    return unless component_enabled?(:model)
    template "model.rb.tt", "app/models/#{model_file_path}.rb"
  end

  def create_application_controller_file
    return if namespace_base_classes_exist?
    template "application_controller.rb.tt", "app/controllers/#{namespace_path}/application_controller.rb"
  end

  def create_controller_file
    return unless component_enabled?(:controller)
    template "controller.rb.tt", "app/controllers/#{controller_file_path}.rb"
  end

  def create_serializer_file
    return unless component_enabled?(:serializer)
    template "serializer.rb.tt", "app/serializers/#{serializer_file_path}.rb"
  end

  def create_policy_file
    return unless component_enabled?(:policy)
    template "policy.rb.tt", "app/policies/#{policy_file_path}.rb"
  end

  def create_fixture_file
    return unless component_enabled?(:fixture)
    return if options[:skip_tests]
    template "fixture.yml.tt", "test/fixtures/#{fixture_file_name}.yml"
  end

  def create_integration_test_file
    return unless component_enabled?(:integration_test)
    return if options[:skip_tests]
    template "integration_test.rb.tt", "test/integration/#{integration_test_file_path}.rb"
  end

  def add_route
    return unless component_enabled?(:route)
    return if options[:skip_routes]
    route "resources :#{plural_name}, except: %i[new edit]", namespace: namespace_path
  end

  def create_locale_file
    return unless component_enabled?(:locale)
    template "locale.en.yml.tt",
      "config/locales/#{namespace_path}/#{file_name}.en.yml"
  end

  def add_fixture_class_mapping
    return if options[:skip_tests]
    return if fixture_class_already_mapped?

    gsub_file "test/test_helper.rb",
      /(\s+\w+:\s+[^,\n]+)(\n(?:\s+\w+|\s+\)))/,
      '\\1,\\2'

    insert_into_file "test/test_helper.rb",
      "      #{fixture_file_name}: #{class_name},\n",
      before: /^\s+\)$/
  end

  private

  def validate_options!
    if options[:only]
      invalid = options[:only] - VALID_COMPONENTS
      if invalid.any?
        raise Thor::Error, "Invalid components for --only: #{invalid.join(', ')}. Valid: #{VALID_COMPONENTS.join(', ')}"
      end
    end

    if options[:skip]
      invalid = options[:skip] - VALID_COMPONENTS
      if invalid.any?
        raise Thor::Error, "Invalid components for --skip: #{invalid.join(', ')}. Valid: #{VALID_COMPONENTS.join(', ')}"
      end
    end
  end

  def component_enabled?(name)
    return false if options[:only] && !options[:only].include?(name.to_s)
    return false if options[:skip]&.include?(name.to_s)
    true
  end

  def interactive?
    options[:interactive]
  end

  def resolve_interactive_options
    unless auditable_flag_explicit?
      options[:auditable] = yes?("Auditable? (Y/n)", :green)
    end

    unless slug_flag_explicit?
      if yes?("Slugable? (y/N)", :green)
        options[:slug] = true
        if options[:slug_source].blank?
          src = ask("Source column? (default: name):", :green)
          options[:slug_source] = src.presence || "name"
        end
      end
    end

    if namespace_new? && !namespace_base_classes_exist?
      if yes?("Namespace `#{namespace_path.camelize}` doesn't exist. Create base classes? (Y/n)", :green)
        # base class files will be created by create_application_record_file etc.
      end
    end
  end

  def auditable_flag_explicit?
    ARGV.include?("--auditable") || ARGV.include?("--no-auditable")
  end

  def slug_flag_explicit?
    slug_source_flag_explicit? || ARGV.include?("--slug") || ARGV.include?("--no-slug")
  end

  def slug_source_flag_explicit?
    ARGV.any? { |a| a.start_with?("--slug-source") }
  end

  def namespace_new?
    namespace_path.present? && !File.exist?("app/models/#{namespace_path}")
  end

  def namespace_base_classes_exist?
    File.exist?("app/models/#{namespace_path}/application_record.rb")
  end

  def fixture_class_already_mapped?
    return true if options[:skip_tests]
    test_helper = File.read("test/test_helper.rb")
    test_helper.include?("#{fixture_file_name}: #{class_name}")
  end

  def timestamp
    Time.current.utc.strftime("%Y%m%d%H%M%S")
  end

  def parsed_columns
    @parsed_columns ||= args.map do |arg|
      if arg =~ COLUMN_RE
        Column.new($1, $2.to_sym, $3)
      else
        raise ArgumentError, "Invalid column format: #{arg}"
      end
    end
  end

  def data_columns
    parsed_columns.reject(&:belongs_to?)
  end

  def belongs_to_columns
    parsed_columns.select(&:belongs_to?)
  end

  def resolve_class_name(col)
    col.class_name || guess_class_name(col)
  end

  def guess_class_name(col)
    "#{namespace_path.camelize}::#{col.name.camelize}"
  end

  def has_name?
    data_columns.any? { |c| c.name == "name" }
  end

  def belongs_to_setup_erb
    belongs_to_columns.map { |c|
      klass = resolve_class_name(c)
      %(@#{c.name} = #{klass}.create!(name: "Setup #{c.name.humanize}"))
    }.join("\n    ")
  end

  def self_referential?(col)
    resolve_class_name(col) == class_name
  end

  def belongs_to_fk_refs_erb
    belongs_to_columns.map { |c| "#{c.name}_id: @#{c.name}.id" }.join(", ")
  end

  def sample_all_create_params_erb
    parts = data_columns.map { |c| "#{c.name}: #{c.sample_value}" }
    parts += belongs_to_columns.map { |c| "#{c.name}_id: @#{c.name}.id" }
    parts.join(", ")
  end

  def sample_all_update_params_erb
    parts = []
    unless data_columns.empty?
      col = data_columns.first
      parts << "#{col.name}: #{col.sample_update_value}"
    end
    parts += belongs_to_columns.map { |c| "#{c.name}_id: @#{c.name}.id" }
    parts.join(", ")
  end

  def auditable?
    options[:auditable]
  end

  def slugable?
    options[:slug] || options[:slug_source].present?
  end

  def slug_source_column
    options[:slug_source] || "name"
  end

  def table_name
    [ *class_path.map(&:underscore), plural_name ].join("_")
  end

  def model_name
    class_name.demodulize
  end

  def namespace_path
    class_path.first
  end

  def model_file_path
    File.join(*class_path, file_name)
  end

  def controller_file_path
    File.join(*class_path, "#{plural_name}_controller")
  end

  def serializer_file_path
    File.join(*class_path, "#{file_name}_serializer")
  end

  def policy_file_path
    File.join(*class_path, "#{file_name}_policy")
  end

  def integration_test_file_path
    File.join(*class_path, "#{plural_name}_test")
  end

  def fixture_file_name
    table_name
  end

  def param_columns
    hash_cols = []
    scalar_cols = parsed_columns.map do |col|
      if col.belongs_to?
        ":#{col.name}_id"
      elsif col.type == :jsonb
        hash_cols << "#{col.name}: {}"
        nil
      else
        ":#{col.name}"
      end
    end.compact
    scalar_cols + hash_cols
  end

  SENSITIVE_ATTRIBUTES = %w[
    password token secret key salt crypt otp auth
    credential ssn sin credit card cvv cvc pin
  ].freeze

  def sensitive_column?(name)
    SENSITIVE_ATTRIBUTES.any? { |pattern| name.downcase.include?(pattern) }
  end

  def ransackable_attributes_list
    %w[id] +
      data_columns.reject { |c| c.type == :jsonb || sensitive_column?(c.name) }.map(&:name) +
      belongs_to_columns.reject { |c| sensitive_column?(c.name) }.map { |c| "#{c.name}_id" } +
      %w[slug created_at updated_at].tap { |list|
        list.delete("slug") unless slugable?
      }
  end

  def serialized_attributes_list
    base = %i[id created_at updated_at]
    base << :slug if slugable?
    (data_columns.map { |c| ":#{c.name}" } +
     belongs_to_columns.map { |c| ":#{c.name}_id" } +
     base.map { |c| ":#{c}" }).uniq
  end
end
