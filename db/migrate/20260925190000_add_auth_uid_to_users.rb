# frozen_string_literal: true

# GXB: the auth.gxb.vc subject id for staff SSO. Listed in deploy/release.json gxb_migrations.
class AddAuthUidToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :auth_uid, :string
    add_index :users, :auth_uid, unique: true
  end
end
