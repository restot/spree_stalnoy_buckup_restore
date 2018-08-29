module Select
  def take_name (name)
    /.*[1-9]_(.*)\.json/.match(name)[1]
  end

  def get_json(id)

    array_of_hashes = Dir.glob(
        Rails.root.join('import', '*.json')
    ).each_with_index.map {
        |e, i| e = {id: i, name: File.basename(e), path: e}
    }.sort_by {|h| h[:name]}
    @hash = {}
    if id.is_i?
      array_of_hashes.each {|x|

        if x[:id].to_i == id.to_i then
          @hash = x
        end
      }
    else
      array_of_hashes.each {|x|
        if take_name(x[:name]) == id then
          @hash = x
        end}
    end

    json = JSON.parse(
        File.read(
            Dir.glob(
                Rails.root.join('import', @hash[:name])
            ).first
        )
    )
    return json

  end

  def taxon_create(master, base_json)
    puts master
    parent = base_json.select {|s| s['id'] == master['parent_id']}.first
    unless parent.nil?
      if Spree::Taxon.find_by(name: parent['name']).nil?
        taxon = base_json.select {|s| s['name'] == parent['name']}.first

        taxon_create(taxon, base_json)

      end

      parent_taxon = Spree::Taxon.find_by(name: parent['name'])
    end


    if Spree::Taxon.find_by(name: master['name']).nil?
      r = Spree::Taxon.create(
          parent_id: (parent.nil?) ? nil : parent_taxon.id,
          position: master['position'],
          taxonomy_id: master['taxonomy_id'],
          name: master['name'],
          description: master['description'],
          meta_title: master['meta_title'],
          meta_description: master['meta_description'],
          meta_keywords: master['meta_keywords'],
          permalink: master['permalink'])

      return r.valid?
    else
      return true
    end

  end

  def check_if_image_need_load(images,name)
    if images.count == 0
      return true
    end
    assets = Spree::Asset.where(viewable_id: images.first.viewable_id)
    filenames = []
    assets.each do |asset|

      filenames << ActiveStorage::Blob.find(ActiveStorage::Attachment.find_by(record_id: asset.id).blob_id).filename
    end
    return !filenames.include?(name.to_s)
  end

  def reload_images(path,offset: 0)
    variants_json =JSON.parse(File.read(path + '/variants.json'))
    assets_json = JSON.parse(File.read(path + '/assets.json'))
    count = Dir.glob('*', base: path.to_s).count
    index = 1
    product_found = false

    Dir.glob('*', base: path.to_s) do |e|
      if offset > index
        index += 1
        next
      end
      spree_product = nil
      this_path = File.join(path.to_s,e.to_s,'original')

      puts "#{__LINE__.to_s} -| "+ this_path
      puts "#{__LINE__.to_s} -| "+ "---#{e}---"
      img_count = Dir.glob('*',base: this_path).count
        Dir.glob('*',base: this_path) do |image|
          puts "#{__LINE__.to_s} -| "+ "image: #{image.inspect}, #{image.class}"
          asset = assets_json.select {|s| s['attachment_file_name'] == image.to_s}.first
          puts "#{__LINE__.to_s} -| "+ asset.inspect
          if asset != nil
            product =  variants_json.select {|s| s['id'] == asset['viewable_id'].to_i}.first
            puts "#{__LINE__.to_s} -| "+ product.inspect
            if product != nil
              spree_product = Spree::Variant.find_by(sku: product['sku'])
              product_found = true
              puts "#{__LINE__.to_s} -| "+ spree_product.inspect
              if spree_product != nil
                check = check_if_image_need_load(spree_product.images,image)
                puts "#{__LINE__.to_s} -| "+ "Check: [#{check}]"
                if check
                  puts "#{__LINE__.to_s} -| "+ "Upload: [#{image}] - product_ID: #{spree_product.id}"
                  file = File.open(File.join(this_path, image))
                  tempfile = Tempfile.new(File.basename(file)).tap{|f| f.binmode; f.write(file.read);f.close }
                  attachment =  ActionDispatch::Http::UploadedFile.new({tempfile: tempfile,filename: File.basename(file),type: "image/#{File.extname(file).to_s.eat!}"}, )
                  Spree::Image.create(viewable_id: spree_product.id, attachment:attachment, viewable_type: 'Spree::Variant',attachment_file_name: File.basename(file))
                  tempfile.unlink
                else
                  product_found = 'loaded!'
                end
              else
              end
            else
              product_found = 'nil'
            end
          else
            product_found = 'no_asset'

          end


        end
      Rails.logger.info "[#{index}/#{count}] old_variant_id: #{e}, viewable_id: #{spree_product.id unless spree_product.nil?}, images: #{img_count}, exist?: #{product_found} __grep__catch__"
      product_found = false
      index += 1
      end

    end



end

class String
  def is_i?
    /\A[-+]?\d+\z/ === self
  end
  def eat!(how_many = 1)
    self.replace self[how_many..-1]
  end
end

module Spree
  module Admin
    class StalnoyImportExportsController < ResourceController

      include Select
      include ActionController::Live

      def index
      end

def api_check         ###########################################################################################

  fails_array = []

  response.headers['Content-Type'] = 'text/event-stream'
  base_json = get_json(params[:ud])
  resp = Hash[status: 'preparing',action:'api_check',id:params[:ud],total:base_json.count]
  loop = false

  case take_name(params[:path])
  when 'country'#-------------------------------------------------------------------------------------------------
    json = base_json.first
    t = Spree::Country.exists?('iso_name' => json['iso_name'],
                               'iso' => json['iso'],
                               'iso3' => json['iso3'],
                               'name' => json['name'],
                               'numcode' => json['numcode'],
                               'states_required' => json['states_required'],
                               'zipcode_required' => json['zipcode_required'])


    resp[:last_row] = (t == true) ? base_json.count : 0
    resp[:result] = t

  when 'states'#-------------------------------------------------------------------------------------------------
    loop = true
    base_json.each_with_index do |h, i|
      t = Spree::State.exists?(name: h['name'], abbr: h['abbr'])

      resp[:last_row] = i + 1
      resp[:result] = t
      response.stream.write "data: #{resp.to_json}\n\n"
      unless t
        fails_array << h.to_json
      end
    end
  when 'taxonomy'#-----------------------------------------------------------------------------------------------
    json = base_json.first
    t = Spree::Taxonomy.exists?(name: json['name'])
    resp[:last_row] = (t == true) ? base_json.count : 0
    resp[:result] = t
  when 'taxons'#-------------------------------------------------------------------------------------------------
    loop = true
    base_json = base_json.sort_by {|h| h['id']}
    base_json.each_with_index do |h, i|
      t = Spree::Taxon.exists?(name: h['name'],permalink: h['permalink'])

      resp[:last_row] = i + 1
      resp[:result] = t
      response.stream.write "data: #{resp.to_json}\n\n"
      unless t
        fails_array << h.to_json
      end
    end
  when 'sale_rate'#----------------------------------------------------------------------------------------------
    loop = true
    base_json = base_json.sort_by {|h| h['id']}
    base_json.each_with_index do |h, i|
      t = Spree::SaleRate.exists?(currency: h['currency'], rate: h['rate'], tag: h['tag'])
      resp[:last_row] = i + 1
      resp[:result] = t
      response.stream.write "data: #{resp.to_json}\n\n"
      unless t
        fails_array << h.to_json
      end
    end

  when 'product'#------------------------------------------------------------------------------------------------
    loop = true
    base_json = base_json.sort_by {|h| h['id']}
    base_json.each_with_index do |h, i|
      t = Spree::Product.exists?(
                                 promotionable: h['promotionable'],
                                 name: h['name'],
                                 description: h['description'],
                                 meta_title: h['meta_title'],
                                 meta_description: h['meta_description'],
                                 meta_keywords: h['meta_keywords'],
                                 slug: h['slug'])
      resp[:last_row] = i + 1
      resp[:result] = t
      response.stream.write "data: #{resp.to_json}\n\n"
      unless t
        fails_array << h.to_json
      end
    end
  when 'product_taxon'#------------------------------------------------------------------------------------------
    base_json = base_json.sort_by {|h| h['id']}
    loop = true
    base_json.each_with_index do |h, i|
      b = false
      h['taxons'].each do |t|
        b = Spree::Product.find_by(slug: h['slug']).taxons.exists?(permalink: t['permalink'])
        unless b
          fails_array << h.to_json
        end
      end
      unless b
        fails_array << h.to_json
      end
      resp[:last_row] = i + 1
      resp[:result] = b
      response.stream.write "data: #{resp.to_json}\n\n"

    end
  when 'variant'#------------------------------------------------------------------------------------------------
    loop = true
    base_json.each_with_index do |h, i|
      a = Spree::Variant.exists?(sku: h['sku'],
                                weight: h['weight'],
                                height: h['height'],
                                width: h['width'],
                                depth: h['depth'],
                                is_master: h['is_master'],
                                cost_price: h['cost_price'],
                                position: h['position'],
                                cost_currency: h['cost_currency'],
                                track_inventory: h['track_inventory'],
                                tax_category_id: h['tax_category_id'])
      unless a
        fails_array << h
      end
      resp[:last_row] = i + 1
      resp[:result] = a
      response.stream.write "data: #{resp.to_json}\n\n"
    end
  when 'assets'#-------------------------------------------------------------------------------------------------
    loop = true
    variants = get_json 'variant'
    active_storage_attachments = get_json 'active_storage_attachments'
    active_storage_blobs = get_json 'active_storage_blobs'
    base_json.each_with_index do |h, i|
      variant = nil
      active_storage_attachment = nil
      active_storage_blob = nil
      spree_variant = nil
      spree_asset = nil
      spree_active_storage_attachment = nil
      spree_active_storage_blob = nil

      variant = variants.select {|p| p['id'] == h['viewable_id']}.first
      active_storage_attachment =  active_storage_attachments.select {|p| p['record_id'] == h['id']}.first
      active_storage_blob = active_storage_blobs.select {|p| p['id'] == active_storage_attachment['blob_id']}.first

      if variant != nil && active_storage_attachment !=nil && active_storage_blob !=nil
        spree_variant = Spree::Variant.find_by(sku: variant['sku'])
        spree_asset = Spree::Asset.find_by(attachment_file_name: h['attachment_file_name'])
        spree_active_storage_attachment = ActiveStorage::Attachment.find_by(record_id: spree_asset.id)
        spree_active_storage_blob = ActiveStorage::Blob.find(spree_active_storage_attachment.blob_id)

        if spree_variant != nil && spree_asset !=nil && spree_active_storage_attachment !=nil && spree_active_storage_blob !=nil
        a = true
        else
          a = false
        end
      else
        a = false
      end

      unless a
        h['variant'] = variant
        h['active_storage_attachment'] = active_storage_attachment
        h['active_storage_blob'] = active_storage_blob
        h['spree_variant'] = (spree_variant.nil?)? nil : spree_variant.attributes
        h['spree_asset'] = (spree_asset.nil?)? nil : spree_asset.attributes
        h['spree_active_storage_attachment'] = (spree_active_storage_attachment.nil?)? nil : spree_active_storage_attachment.attributes
        h['spree_active_storage_blob'] = (spree_active_storage_blob.nil?)? nil : spree_active_storage_blob.attributes
        fails_array << h.to_json
      end
      resp[:last_row] = i + 1
      resp[:result] = a
      response.stream.write "data: #{resp.to_json}\n\n"
    end
  when 'properties'#---------------------------------------------------------------------------------------------
    loop = true
    base_json.each_with_index do |h, i|
      a = Spree::Property.exists?(name: h['name'], presentation: h['presentation'])
      unless a
        fails_array << h.to_json
      end
      resp[:last_row] = i + 1
      resp[:result] = a
      response.stream.write "data: #{resp.to_json}\n\n"
    end
  when 'product_property'#---------------------------------------------------------------------------------------
    loop = true
    products = get_json 'product'
    properties = get_json 'properties'
    base_json.each_with_index do |h, i|
      product = nil
      property = nil
      spree_product = nil
      spree_property = nil
      product = products.select {|p| p['id'] == h['product_id']}.first
      property = properties.select {|p| p['id'] == h['property_id']}.first
      if property != nil && product !=nil
        spree_product = Spree::Product.find_by(slug: product['slug'])
        spree_property = Spree::Property.find_by(name: property['name'], presentation: property['presentation'])
        if spree_product != nil && spree_property !=nil
          a = Spree::ProductProperty.where(product_id: spree_product.id, property_id: spree_property.id).exists?(value: h['value'])
        else
          a = false
        end

      else
        a = false
      end

      unless a
        h['product'] = product
        h['property'] = property
        h['spree_product'] = (spree_product.nil?)? nil : spree_product.attributes
        h['spree_property'] = (spree_property.nil?)? nil : spree_property.attributes
        fails_array << h.to_json
      end
      resp[:last_row] = i + 1
      resp[:result] = a
      response.stream.write "data: #{resp.to_json}\n\n"
    end
  when 'stalnoy_import'#-----------------------------------------------------------------------------------------
      loop = true
      base_json.each_with_index do |h, i|

        a = Spree::StalnoyImport.exists?(name: h['name'],
                                        cols: h['cols'],
                                        rows: h['rows'],
                                        data: h['data'],
                                        data_prepared: h['data_prepared'],
                                        last_row: h['last_row'])
        unless a
          fails_array << h.to_json
        end
        resp[:last_row] = i + 1
        resp[:result] = a
        response.stream.write "data: #{resp.to_json}\n\n"
      end




  else
    json = get_json(params[:ud])

    response.stream.write "data: #{Hash['status' => 'preparing',
                                        'total' => json.count,
                                        'last_row' => 0,
                                        'hash' => params[:path],
                                        'id' => params[:ud]

    ].to_json}\n\n"
  end
  if loop
    resp[:status] = 'done'
    resp[:text] = ''
    response.stream.write "data: #{resp.to_json}\n\n"
  end
  response.stream.write "data: #{resp.to_json}\n\n" unless loop
  unless fails_array.empty?
    resp[:status] = 'report'
    resp[:action] = 'show_fails'
    resp[:content] = fails_array
    response.stream.write "data: #{resp.to_json}\n\n"
  end
rescue IOError, ActionController::Live::ClientDisconnected
  logger.info 'Stream closed'
rescue StandardError => e
  response.stream.write "data: #{Hash['status' => 'error',
                                      'content' => e,
                                      'trace' => e.backtrace
  ].to_json}\n\n"
ensure
  response.stream.close
end

def api_put           ###########################################################################################
  response.headers['Content-Type'] = 'text/event-stream'

  base_json = get_json(params[:ud])

  fails_array = []

  case take_name(params[:path])
  when 'country'#------------------------------------------------------------------------------------------------

    json = base_json.first
    a = Spree::Country.create!(id: json['id'],
                               'iso_name' => json['iso_name'],
                               'iso' => json['iso'],
                               'iso3' => json['iso3'],
                               'name' => json['name'],
                               'numcode' => json['numcode'],
                               'states_required' => json['states_required'],
                               'zipcode_required' => json['zipcode_required'])

    response.stream.write "data: #{Hash['status' => 'work',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'result' => a.valid?
    ].to_json}\n\n"
    unless a.valid?
      fails_array << h
    end
    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"

  when 'states'#-------------------------------------------------------------------------------------------------

    base_json.each_with_index do |h, i|

      a = Spree::State.create!(name: h['name'], abbr: h['abbr'], country_id: h['country_id'])
      response.stream.write "data: #{Hash['status' => 'work',
                                          'action' => 'api_put',
                                          'total' => base_json.count,
                                          'last_row' => i + 1,
                                          'hash' => params[:path],
                                          'id' => params[:ud],
                                          'obj_id' => h['id'],
                                          'result' => a.valid?
      ].to_json}\n\n"
      unless a.valid?
        fails_array << h
      end
    end
    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"
  when 'taxonomy'#-----------------------------------------------------------------------------------------------
    json = base_json.first
    a = Spree::Taxonomy.create!(id: json['id'], position: json['position'], name: json['name'])
    response.stream.write "data: #{Hash['status' => 'work',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'result' => a.valid?
    ].to_json}\n\n"
    unless a.valid?
      fails_array << h
    end
    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"
  when 'taxons'#-------------------------------------------------------------------------------------------------
    base_json = base_json.each {|h|
      if h['parent_id'] == nil then
        h['parent_id'] = 0
      end}
    base_json = base_json.sort_by {|h| h['id']}
    base_json = base_json.each_with_index {|h, i| h.merge!('index' => i + 1)}
    base_json = base_json.sort_by {|h| h['parent_id']}


    base_json.each_with_index do |h, i|

      ret = taxon_create(h, base_json)

      response.stream.write "data: #{Hash['status' => 'work',
                                          'action' => 'api_put',
                                          'total' => base_json.count,
                                          'last_row' => i + 1,
                                          'hash' => params[:path],
                                          'id' => params[:ud],
                                          'obj_id' => h['id'],
                                          'result' => ret
      ].to_json}\n\n"
      unless ret
        fails_array << h
      end
    end

    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"


  when 'sale_rate'#----------------------------------------------------------------------------------------------

    base_json = base_json.sort_by {|h| h['id']}
    base_json.each_with_index do |h, i|

      a = Spree::SaleRate.create(id: h['id'], currency: h['currency'], rate: h['rate'], tag: h['tag'])

      response.stream.write "data: #{Hash['status' => 'work',
                                          'action' => 'api_put',
                                          'total' => base_json.count,
                                          'last_row' => i + 1,
                                          'hash' => params[:path],
                                          'id' => params[:ud],
                                          'obj_id' => h['id'],
                                          'result' => a.valid?
      ].to_json}\n\n"

      unless a.valid?
        fails_array << h
      end
    end

    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"

  when 'product'#------------------------------------------------------------------------------------------------
    variants_json = get_json('variant')
    base_json = base_json.sort_by {|h| h['id']}

    base_json.each_with_index do |h, i|
      startt = Time.now
      a = Spree::Product.create!(
          sku: variants_json.select {|s| s['product_id'] == h['id']}.first['sku'],
          available_on: h['available_on'],
          deleted_at: h['deleted_at'],
          tax_category_id: h['tax_category_id'],
          shipping_category_id: h['shipping_category_id'],
          promotionable: h['promotionable'],
          discontinue_on: h['discontinue_on'],
          name: h['name'],
          description: h['description'],
          meta_title: h['meta_title'],
          meta_description: h['meta_description'],
          meta_keywords: h['meta_keywords'],
          slug: h['slug'],
          price: 0)

      endt = Time.now
      diff = endt - startt
      if diff < 0.03
        sleep(0.03 - diff)
      end

      response.stream.write "data: #{Hash['status' => 'work',
                                          'action' => 'api_put',
                                          'total' => base_json.count,
                                          'last_row' => i + 1,
                                          'hash' => params[:path],
                                          'id' => params[:ud],
                                          'obj_id' => h['id'],
                                          'result' => a.valid?
      ].to_json}\n\n"
      unless a.valid?
        fails_array << h
      end
    end
    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"
  when 'price'#--------------------------------------------------------------------------------------------------
    # base_json.each_with_index do |h, i|
    #   startt = Time.now
    #   a = Spree::Price.find_by(variant_id: h['variant_id'])
    #   if a.nil? then
    #     a = false
    #     fails_array << h
    #   else
    #     a.update(amount: h['amount'], currency: h['currency'])
    #   end
    #   endt = Time.now
    #   diff = endt - startt
    #   if diff < 0.03
    #     sleep(0.03 - diff)
    #   end
    #   response.stream.write "data: #{Hash['status' => 'work',
    #                                       'action' => 'api_put',
    #                                       'total' => base_json.count,
    #                                       'last_row' => i + 1,
    #                                       'hash' => params[:path],
    #                                       'id' => params[:ud],
    #                                       'obj_id' => h['id'],
    #                                       'result' => (a == false) ? a : a.valid?
    #   ].to_json}\n\n"
    # end
    # response.stream.write "data: #{Hash['status' => 'done',
    #                                     'action' => 'api_put',
    #                                     'total' => base_json.count,
    #                                     'last_row' => base_json.count,
    #                                     'hash' => params[:path],
    #                                     'id' => params[:ud],
    #                                     'fails_array' => fails_array
    # ].to_json}\n\n"
  when 'product_taxon'#------------------------------------------------------------------------------------------
    count = 0
    base_json.each {|t| count = count + t['products'].count}
    product_json = get_json 'product'
    count_index = 0
    base_json.each_with_index do |h, i|
      if h['products'] != nil
        products = h['products']
        products.each_with_index do |p, pI|
          product = product_json.select {|s| s['slug'] == p['slug']}.first
          if Spree::Product.find_by(name: product['name']).nil?
            response.stream.write "data: #{Hash['status' => 'work',
                                                'action' => 'api_put',
                                                'total' => count,
                                                'last_row' => count_index,
                                                'hash' => params[:path],
                                                'id' => params[:ud],
                                                'obj_id' => h['id'],
                                                'fallback' => 'product nil',
                                                'result' => false
            ].to_json}\n\n"
            next
          end
          r = Spree::Product.find_by(slug: p['slug']).taxons = Spree::Taxon.where(name: h['name'])
          count_index += 1;
          response.stream.write "data: #{Hash['status' => 'work',
                                              'action' => 'api_put',
                                              'total' => count,
                                              'last_row' => count_index,
                                              'hash' => params[:path],
                                              'id' => params[:ud],
                                              'obj_id' => h['id'],
                                              'result' => !r.first.nil?
          ].to_json}\n\n"
          if r.first.nil?
            fails_array << p
          end
        end
      end

    end

    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => count,
                                        'last_row' => count_index,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"

  when 'variant'#------------------------------------------------------------------------------------------------
    product_json = get_json('product')
    base_json = base_json.sort_by {|h| h['id']}
    base_json.each_with_index do |h, i|
      product = product_json.select {|s| s['id'] == h['product_id']}.first
      product = Spree::Product.find_by(name: product['name'])

      a = (product.nil?) ? nil : Spree::Variant.find_by(product_id: product.id)
      if !a.nil? then
        a.update(weight: h['weight'],
                 height: h['height'],
                 width: h['width'],
                 depth: h['depth'],
                 is_master: h['is_master'],
                 cost_price: h['cost_price'],
                 position: h['position'],
                 cost_currency: h['cost_currency'],
                 track_inventory: h['track_inventory'],
                 tax_category_id: h['tax_category_id'],
                 discontinue_on: h['discontinue_on'])
      else
        fails_array << h
      end
      response.stream.write "data: #{Hash['status' => 'work',
                                          'action' => 'api_put',
                                          'total' => base_json.count,
                                          'last_row' => i + 1,
                                          'hash' => params[:path],
                                          'id' => params[:ud],
                                          'obj_id' => h['id'],
                                          'result' => !a.nil?
      ].to_json}\n\n"
    end
    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"
  when 'assets'#-------------------------------------------------------------------------------------------------
    variants_json = get_json('variant')

    base_json.each_with_index do |h, i|
      select = variants_json.select {|s| s['id'] == h['viewable_id']}.first
      viewable_id = Spree::Variant.find_by(sku: select['sku'])
      unless viewable_id.nil?

        a = Spree::Asset.create!(id: h['id'],
                                 viewable_type: h['viewable_type'],
                                 viewable_id: viewable_id.id,
                                 attachment_width: h['attachment_width'],
                                 attachment_height: h['attachment_height'],
                                 attachment_file_size: h['attachment_file_size'],
                                 position: h['position'],
                                 attachment_content_type: h['attachment_content_type'],
                                 attachment_file_name: h['attachment_file_name'],
                                 attachment_updated_at: h['attachment_updated_at'],
                                 alt: h['alt'])
        if a.valid?
          a.update(type: 'Spree::Image')
        else
          fails_array << h
        end
      end

      response.stream.write "data: #{Hash['status' => 'preparing',
                                          'action' => 'api_put',
                                          'total' => base_json.count,
                                          'last_row' => i + 1,
                                          'hash' => params[:path],
                                          'id' => params[:ud],
                                          'obj_id' => h['id'],
                                          'result' => viewable_id.nil? ? false : a.valid?
      ].to_json}\n\n"
    end
    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"
  when 'properties'#---------------------------------------------------------------------------------------------
    base_json.each_with_index do |h, i|
      a = Spree::Property.create!(name: h['name'], presentation: h['presentation'])
      response.stream.write "data: #{Hash['status' => 'work',
                                          'action' => 'api_put',
                                          'total' => base_json.count,
                                          'last_row' => i + 1,
                                          'hash' => params[:path],
                                          'id' => params[:ud],
                                          'obj_id' => h['id'],
                                          'result' => a.valid?
      ].to_json}\n\n"
      unless a.valid?
        fails_array << h
      end
    end
    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"

  when 'product_property'#---------------------------------------------------------------------------------------
    product_json = get_json 'product'
    property_json = get_json 'properties'

    base_json.each_with_index do |h, i|


      product = product_json.select {|s| s['id'] == h['product_id']}.first
      product = Spree::Product.find_by(name: product['name'])

      property = property_json.select {|s| s['id'] == h['property_id']}.first
      property = Spree::Property.find_by(name: property['name'])

      if !property.nil? and !product.nil? then

        a = Spree::ProductProperty.create!(value: h['value'],
                                           product_id: product.id,
                                           property_id: property.id,
                                           position: h['position'])
        response.stream.write "data: #{Hash['status' => 'work',
                                            'action' => 'api_put',
                                            'total' => base_json.count,
                                            'last_row' => i + 1,
                                            'hash' => params[:path],
                                            'id' => params[:ud],
                                            'obj_id' => h['id'],
                                            'result' => !a.nil?
        ].to_json}\n\n"
      else
        fails_array << h
        response.stream.write "data: #{Hash['status' => 'work',
                                            'action' => 'api_put',
                                            'total' => base_json.count,
                                            'last_row' => i + 1,
                                            'hash' => params[:path],
                                            'id' => params[:ud],
                                            'obj_id' => h['id'],
                                            'result' => false
        ].to_json}\n\n"
      end
    end
    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"
  when 'stalnoy_import'#-----------------------------------------------------------------------------------------
    base_json = base_json.sort_by {|h| h['id']}
    base_json.each_with_index do |h, i|

      a = Spree::StalnoyImport.create(name: h['name'],
                                      cols: h['cols'],
                                      rows: h['rows'],
                                      data: h['data'],
                                      data_prepared: h['data_prepared'],
                                      last_row: h['last_row'])
      response.stream.write "data: #{Hash['status' => 'work',
                                          'action' => 'api_put',
                                          'total' => base_json.count,
                                          'last_row' => i + 1,
                                          'hash' => params[:path],
                                          'id' => params[:ud],
                                          'obj_id' => h['id'],
                                          'result' => a.valid?
      ].to_json}\n\n"

      unless a.valid?
        fails_array << h
      end
    end
    response.stream.write "data: #{Hash['status' => 'done',
                                        'action' => 'api_put',
                                        'total' => base_json.count,
                                        'last_row' => base_json.count,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"


  else
  end#-----------------------------------------------------------------------------------------------------------
rescue IOError, ActionController::Live::ClientDisconnected
  logger.info 'Stream closed'
rescue StandardError => e
  response.stream.write "data: #{Hash['status' => 'error',
                                      'content' => e,
                                      'trace' => e.backtrace.join("\n")
  ].to_json}\n\n"
ensure
  response.stream.close
end

def api_get           ###########################################################################################
  response.headers['Content-Type'] = 'text/event-stream'
  resp = Hash[action:'api_get',id:params[:ud]]

  case take_name(params[:path])
  when 'country'#------------------------------------------------------------------------------------------------
   t = File.open(File.path(Rails.root.join('export/1.1_country.json')) , 'w+') {|f| f.write(Spree::Country.all.to_json) }
  when 'states'#-------------------------------------------------------------------------------------------------
    t = File.open(File.path(Rails.root.join('export/1.2_states.json')) , 'w+') {|f| f.write(Spree::State.all.to_json) }
  when 'taxonomy'#-----------------------------------------------------------------------------------------------
    t = File.open(File.path(Rails.root.join('export/2.1_taxonomy.json')) , 'w+') {|f| f.write(Spree::Taxonomy.all.to_json) }
  when 'taxons'#-------------------------------------------------------------------------------------------------
    t = File.open(File.path(Rails.root.join('export/2.2_taxons.json')) , 'w+') {|f| f.write(Spree::Taxon.order('parent_id ASC').to_json) }
  when 'sale_rate'#----------------------------------------------------------------------------------------------
    t = File.open(File.path(Rails.root.join('export/3_sale_rate.json')) , 'w+') {|f| f.write(Spree::SaleRate.all.to_json) }
  when 'product'#------------------------------------------------------------------------------------------------
    t = File.open(File.path(Rails.root.join('export/4.1_product.json')) , 'w+') {|f| f.write(Spree::Product.all.to_json) }
  when 'price'#--------------------------------------------------------------------------------------------------
    t = File.open(File.path(Rails.root.join('export/4.2_price.json')) , 'w+') {|f| f.write(Spree::Price.all.to_json) }
  when 'product_taxon'#------------------------------------------------------------------------------------------
    pt = []
    Spree::Product.all.each{|p| h = {'id'=>p.id, 'name' => p.name, 'slug'=>p.slug,'taxons'=>[]}; p.taxons.each{|t| h['taxons'] << {'id' => t.id, 'parent_id' => t.parent.id, 'permalink' => t.permalink, 'name' => t.name, 'taxonomy_id' => t.taxonomy_id, 'position' => t.position}};pt << h }
    t = File.open(File.path(Rails.root.join('export/4.3_product_taxon.json')) , 'w+') {|f| f.write(pt.to_json) }
  when 'variant'#------------------------------------------------------------------------------------------------
    t = File.open(File.path(Rails.root.join('export/5.1_variant.json')) , 'w+') {|f| f.write(Spree::Variant.all.to_json) }
  when 'assets'#-------------------------------------------------------------------------------------------------
    t = File.open(File.path(Rails.root.join('export/5.2_assets.json')) , 'w+') {|f| f.write(Spree::Image.all.to_json) }
  when 'properties'#---------------------------------------------------------------------------------------------
    t = File.open(File.path(Rails.root.join('export/5.5_properties.json')) , 'w+') {|f| f.write(Spree::Property.all.to_json) }
  when 'product_property'#---------------------------------------------------------------------------------------
    t = File.open(File.path(Rails.root.join('export/5.6_product_property.json')) , 'w+') {|f| f.write(Spree::ProductProperty.all.to_json) }
  when 'stalnoy_import'#-----------------------------------------------------------------------------------------
    t = File.open(File.path(Rails.root.join('export/6_stalnoy_import.json')) , 'w+') {|f| f.write(Spree::StalnoyImport.all.to_json) }
  when 'active_storage_attachments'
    t = File.open(File.path(Rails.root.join('export/5.3_active_storage_attachments.json')) , 'w+') {|f| f.write(ActiveStorage::Attachment.all.to_json) }
  when 'active_storage_blobs'
    t = File.open(File.path(Rails.root.join('export/5.4_active_storage_blobs.json')) , 'w+') {|f| f.write(ActiveStorage::Blob.all.all.to_json) }
  end
  resp[:status] = 'done'
  resp[:total] = 1
  resp[:text] = t.to_s + ' bytes '
  resp[:last_row] = 1
  resp[:result] = true
  response.stream.write "data: #{resp.to_json}\n\n"
rescue IOError, ActionController::Live::ClientDisconnected
  logger.info 'Stream closed'
rescue StandardError => e
  response.stream.write "data: #{Hash['status' => 'error',
                                      'content' => e,
                                      'trace' => e.backtrace
  ].to_json}\n\n"
ensure
  response.stream.close
end

    end
  end
end
