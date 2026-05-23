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

  class_option :auditable, type: :boolean, default: true
  class_option :slug, type: :boolean, default: false
  class_option :slug_source, type: :string, default: nil
  class_option :skip_migration, type: :boolean, default: false
  class_option :skip_routes, type: :boolean, default: false
  class_option :skip_tests, type: :boolean, default: false
  class_option :interactive, type: :boolean, default: true

  COLUMN_RE = /\A
    (\w+)                     # name
    :
    (string|text|integer|decimal|float|boolean|date|datetime|jsonb|belongs_to)
    (?:\[(\w+(?:::\w+)*)\])?  # optional bracketed class_name for belongs_to
  \z/x

  def initialize(*)
    super
    return unless behavior == :invoke
    resolve_interactive_options if interactive?
  end

  def create_migration_file
    return if options[:skip_migration]
    template "migration.rb.tt", "db/migrate/#{timestamp}_create_#{table_name}.rb"
  end

  def create_application_record_file
    return if namespace_base_classes_exist?
    template "application_record.rb.tt", "app/models/#{namespace_path}/application_record.rb"
  end

  def create_model_file
    template "model.rb.tt", "app/models/#{model_file_path}.rb"
  end

  def create_application_controller_file
    return if namespace_base_classes_exist?
    template "application_controller.rb.tt", "app/controllers/#{namespace_path}/application_controller.rb"
  end

  def create_controller_file
    template "controller.rb.tt", "app/controllers/#{controller_file_path}.rb"
  end

  def create_serializer_file
    template "serializer.rb.tt", "app/serializers/#{serializer_file_path}.rb"
  end

  def create_policy_file
    template "policy.rb.tt", "app/policies/#{policy_file_path}.rb"
  end

  def create_fixture_file
    return if options[:skip_tests]
    template "fixture.yml.tt", "test/fixtures/#{fixture_file_name}.yml"
  end

  def create_model_test_file
    return if options[:skip_tests]
    template "model_test.rb.tt", "test/models/#{model_test_file_path}.rb"
  end

  def create_integration_test_file
    return if options[:skip_tests]
    template "integration_test.rb.tt", "test/integration/#{integration_test_file_path}.rb"
  end

  def add_route
    return if options[:skip_routes]
    route "resources :#{plural_name}, except: %i[new edit]", namespace: namespace_path
  end

  def add_fixture_class_mapping
    return if options[:skip_tests]
    return if fixture_class_already_mapped?

    sentinel = /events_categories:\s+Events::Category/
    mapping = ",\n      #{fixture_file_name}: #{class_name},"
    insert_into_file "test/test_helper.rb", mapping, after: sentinel, verbose: true
  end

  private

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
      %(result = #{klass}.connection.execute("INSERT INTO \#{#{klass}.table_name} (name, slug, created_at, updated_at) VALUES ('Setup #{c.name.humanize}', 'setup-#{c.name}-' || gen_random_uuid()\\:\\:text, NOW(), NOW()) RETURNING id"); @#{c.name} = #{klass}.find(result.first["id"]))
    }.join("\n    ")
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

  def model_test_file_path
    File.join(*class_path, "#{file_name}_test")
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
    scalar_cols << ":active" unless data_columns.any? { |c| c.name == "active" }
    scalar_cols + hash_cols + [ "metadata: {}" ]
  end

  def ransackable_attributes_list
    %w[id] +
      data_columns.reject { |c| c.type == :jsonb }.map(&:name) +
      belongs_to_columns.map { |c| "#{c.name}_id" } +
      %w[slug active created_at updated_at].tap { |list|
        list.delete("active") if data_columns.any? { |c| c.name == "active" }
        list.delete("slug") unless slugable?
      }
  end

  def serialized_attributes_list
    base = %i[id metadata active created_at updated_at]
    base << :slug if slugable?
    (data_columns.map { |c| ":#{c.name}" } + base.map { |c| ":#{c}" }).uniq
  end
end
