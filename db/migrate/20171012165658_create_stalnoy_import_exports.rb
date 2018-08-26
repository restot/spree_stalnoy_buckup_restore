class CreateStalnoyImportExports <  SpreeExtension::Migration[5.1]
  def self.up
    create_table :spree_stalnoy_import_exports do |t|
    end
  end

  def self.down
    drop_table :spree_stalnoy_import_exports
  end

end
