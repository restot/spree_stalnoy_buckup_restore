Deface::Override.new(
    virtual_path: 'spree/layouts/admin',
    name: 'stalnoy_import_export_admin_sidebar_menu',
    insert_bottom: '#main-sidebar',
    partial: 'spree/admin/shared/import_exports_sidebar_menu'
)