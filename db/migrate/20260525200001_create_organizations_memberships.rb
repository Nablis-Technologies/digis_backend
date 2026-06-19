class CreateOrganizationsMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations_memberships, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :user, null: false, foreign_key: { to_table: :core_users }, type: :uuid
      t.references :organization, null: false, foreign_key: { to_table: :organizations_organizations }, type: :uuid
      t.string :role, null: false, default: "staff"
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_index :organizations_memberships, [ :user_id, :organization_id ], unique: true,
              name: "idx_org_memberships_on_user_and_org"
    add_index :organizations_memberships, :status

    execute <<-SQL
      CREATE UNIQUE INDEX idx_one_owner_per_org
        ON organizations_memberships (organization_id)
        WHERE role = 'owner';
    SQL
  end
end
