class AddSocialFieldsToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations_organizations, :social_links, :jsonb, default: {}
    add_column :organizations_organizations, :followers_count, :integer, default: 0, null: false
  end
end
