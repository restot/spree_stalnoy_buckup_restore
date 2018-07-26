Spree::Core::Engine.add_routes do
  # Add your extension routes here
   namespace :admin, path: Spree.admin_path do

     get 'stalnoy_io_index', to: 'stalnoy_import_exports#index'
     get '/stalnoy_io/get/*path/*ud', to: 'stalnoy_import_exports#api_get', as: 'stalnoy_io_api_get'
     get '/stalnoy_io/put/*path/*ud', to: 'stalnoy_import_exports#api_put', as: 'stalnoy_io_api_put'
   end
end
