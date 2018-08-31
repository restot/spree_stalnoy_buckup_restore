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
    parent = base_json.detect {|s| s['id'] == master['parent_id']}
    unless parent.nil?
      if Spree::Taxon.find_by(name: parent['name']).nil?
        taxon = base_json.detect {|s| s['name'] == parent['name']}

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
    if images.length == 0
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
    count = Dir.glob('*', base: path.to_s).length
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
      img_count = Dir.glob('*',base: this_path).length
        Dir.glob('*',base: this_path) do |image|
          puts "#{__LINE__.to_s} -| "+ "image: #{image.inspect}, #{image.class}"
          asset = assets_json.detect {|s| s['attachment_file_name'] == image.to_s}
          puts "#{__LINE__.to_s} -| "+ asset.inspect
          if asset != nil
            product =  variants_json.detect {|s| s['id'] == asset['viewable_id'].to_i}
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
    # noinspection ALL
    class StalnoyImportExportsController < ResourceController

      include Select
      include ActionController::Live

      def index
      end

def api_check         ###########################################################################################

  fails_array = []

  response.headers['Content-Type'] = 'text/event-stream'
  base_json = get_json(params[:ud])
  resp = Hash[status: 'preparing',action:'api_check',id:params[:ud],total:base_json.length]
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


    resp[:last_row] = (t == true) ? base_json.length : 0
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
    resp[:last_row] = (t == true) ? base_json.length : 0
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

      variant = variants.detect {|p| p['id'] == h['viewable_id']}
      active_storage_attachment =  active_storage_attachments.detect {|p| p['record_id'] == h['id']}
      active_storage_blob = active_storage_blobs.detect {|p| p['id'] == active_storage_attachment['blob_id']}

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
      product = products.detect {|p| p['id'] == h['product_id']}
      property = properties.detect {|p| p['id'] == h['property_id']}
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

    resp[:last_row] = 0
    resp[:result] = false

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

  resp = Hash[status: 'work',action:'api_put',id:params[:ud],total:base_json.length]
  loop = false

  case take_name(params[:path])
  when 'country'#------------------------------------------------------------------------------------------------
    json = base_json.first
    a = Spree::Country.create!('iso_name' => json['iso_name'],
                               'iso' => json['iso'],
                               'iso3' => json['iso3'],
                               'name' => json['name'],
                               'numcode' => json['numcode'],
                               'states_required' => json['states_required'],
                               'zipcode_required' => json['zipcode_required'])


    resp[:last_row] = base_json.length
    resp[:result] = a.valid?
    unless a.valid?
      fails_array << json
    end
  when 'states'#-------------------------------------------------------------------------------------------------
    loop = true
    countries = get_json 'country'

    base_json.each_with_index do |h, i|
      country = nil
      spree_country = nil
      country = countries.detect{|c| c['id'] == h['country_id']}
      if country != nil
        spree_country = Spree::Country.find_by(iso_name: country['iso_name'])
        if spree_country !=nil
          a = Spree::State.create!(name: h['name'], abbr: h['abbr'], country_id: spree_country.id)

        else
          a = false
        end

      else
        a = false
      end
      unless a.valid? || a == true
        h['country'] = country
        h['spree_country'] = (spree_country.nil?)? nil : spree_country.attributes
        fails_array << h
      end
      resp[:last_row] = i + 1
      resp[:result] = a.valid?
      response.stream.write "data: #{resp.to_json}\n\n"
    end
  when 'taxonomy'#-----------------------------------------------------------------------------------------------
    json = base_json.first
    a = Spree::Taxonomy.create!(position: json['position'], name: json['name'])

    resp[:last_row] = base_json.length
    resp[:result] = a.valid?
    unless a.valid?
      fails_array << json
    end
  when 'taxons'#-------------------------------------------------------------------------------------------------
   loop = true
    base_json = base_json.each {|h|
      if h['parent_id'] == nil then
        h['parent_id'] = 0
      end}
    base_json = base_json.sort_by {|h| h['id']}
    base_json = base_json.each_with_index {|h, i| h['index'] = i + 1}
    base_json = base_json.sort_by {|h| h['parent_id']}


    base_json.each_with_index do |h, i|

      ret = taxon_create(h, base_json)

      resp[:last_row] =  i + 1
      resp[:result] = ret
      response.stream.write "data: #{resp.to_json}\n\n"
      unless ret
        fails_array << h
      end

    end
  when 'sale_rate'#----------------------------------------------------------------------------------------------
    loop = true
    base_json = base_json.sort_by {|h| h['id']}
    base_json.each_with_index do |h, i|

      a = Spree::SaleRate.create(currency: h['currency'], rate: h['rate'], tag: h['tag'])

      resp[:last_row] =  i + 1
      resp[:result] = a.valid?
      response.stream.write "data: #{resp.to_json}\n\n"
      unless a.valid?
        fails_array << h
      end
    end
  when 'product'#------------------------------------------------------------------------------------------------
    loop = true
    variants = get_json'variant'
    prices = get_json 'price'
    base_json = base_json.sort_by {|h| h['id']}

    base_json.each_with_index do |h, i|
      variant = nil
      price = nil
      variant = variants.detect {|s| s['product_id'] == h['id']}
      price = prices.detect{|p| p['variant_id'] == variant['id']}
      if price != nil && variant != nil
        a = Spree::Product.create!(
            sku: variant['sku'],
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
            price: (price['amount'].nil?)? price['amount'] : price['amount'].to_d,
            weight: (variant['weight'].nil?)? variant['weight'] : variant['weight'].to_d,
            height: (variant['height'].nil?)? variant['height'] : variant['height'].to_d,
            width: (variant['width'].nil?)? variant['width'] : variant['width'].to_d,
            depth: (variant['depth'].nil?)? variant['depth'] : variant['depth'].to_d,
            is_master: variant['is_master'],
            cost_price: (variant['cost_price'].nil?)? variant['cost_price'] : variant['cost_price'].to_d,
            cost_currency: variant['cost_currency'],
            tax_category_id: variant['tax_category_id'],
            discontinue_on: variant['discontinue_on'] )
      else
        a = false
      end
      resp[:last_row] = i + 1
      resp[:result] = a.valid?
      response.stream.write "data: #{resp.to_json}\n\n"
      unless a.valid? || a == true
        h['variant'] = variant
        h['price'] = price
        fails_array << h
      end
    end
  when 'price'#--------------------------------------------------------------------------------------------------
  when 'product_taxon'#------------------------------------------------------------------------------------------
    loop = true
    products = get_json 'product'
    base_json.each_with_index do |h, i|
      spree_taxon = nil
      if h['taxons'] != nil
        h['taxons'].each do |t|
          spree_taxon = Spree::Taxon.find_by(permalink: t['permalink'])
          if spree_taxon != nil
            spree_product_taxons = []
            Spree::Product.find_by(slug: h['slug']).taxons.each {|t| spree_product_taxons << t}
            spree_product_taxons << spree_taxon
            r = Spree::Product.find_by(slug: h['slug']).taxons= spree_product_taxons
            resp[:last_row] = i + 1
            resp[:result] = !r.first.nil?
            response.stream.write "data: #{resp.to_json}\n\n"
            if r.first.nil?
              fails_array << h
            end
          else
            resp[:last_row] = i + 1
            resp[:result] = false
            h['note'] = 'TAXON NOT FOUND'
            fails_array << h
            response.stream.write "data: #{resp.to_json}\n\n"
          end
        end
      else
        resp[:last_row] = i + 1
        resp[:result] = false
        h['note'] = 'NO TAXONS'
        fails_array << h
        response.stream.write "data: #{resp.to_json}\n\n"
      end
    end
  when 'variant'#------------------------------------------------------------------------------------------------
    product_json = get_json('product')
    base_json = base_json.sort_by {|h| h['id']}
    base_json.each_with_index do |h, i|
      product = product_json.detect {|s| s['id'] == h['product_id']}
      product = Spree::Product.find_by(name: product['name'])

      a = (product.nil?) ? nil : Spree::Variant.find_by(product_id: product.id)
      if !a.nil? then
        a.update(weight: h['weight'],
                 height: h['height'],
                 width: h['width'],
                 depth: h['depth'],
                 tax_category_id: h['tax_category_id'],
                 discontinue_on: h['discontinue_on'])
      else
        fails_array << h
      end
      resp[:last_row] = i + 1
      resp[:result] = !a.nil?
      response.stream.write "data: #{resp.to_json}\n\n"
    end
  when 'assets'#-------------------------------------------------------------------------------------------------
    loop = true
    variants_json = get_json('variant')

    base_json.each_with_index do |h, i|
      select = variants_json.detect {|s| s['id'] == h['viewable_id']}
      viewable_id = Spree::Variant.find_by(sku: select['sku'])
      unless viewable_id.nil?
        a = Spree::Asset.create!(viewable_type: h['viewable_type'],
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
      resp[:last_row] = i + 1
      resp[:result] = viewable_id.nil? ? false : a.valid?
      response.stream.write "data: #{resp.to_json}\n\n"
    end
  when 'properties'#---------------------------------------------------------------------------------------------
      index = 0
      while index < base_json.size
        h = base_json[index]

        a = Spree::Property.create!(name: h['name'], presentation: h['presentation'])
        resp[:last_row] = index + 1
        resp[:result] = a.valid?
        response.stream.write "data: #{resp.to_json}\n\n"
        unless a.valid?
          fails_array << h
        end
        index += 1
      end
  when 'product_property'#---------------------------------------------------------------------------------------
    product_json = get_json 'product'
    property_json = get_json 'properties'

    index = 0
    while index < base_json.size
      h = base_json[index]

      product = product_json.detect {|s| s['id'] == h['product_id']}
      product = Spree::Product.find_by(name: product['name'])

      property = property_json.detect {|s| s['id'] == h['property_id']}
      property = Spree::Property.find_by(name: property['name'])

      if !property.nil? and !product.nil? then

        a = Spree::ProductProperty.create!(value: h['value'],
                                           product_id: product.id,
                                           property_id: property.id,
                                           position: h['position'])

        resp[:last_row] = index + 1
        resp[:result] = !a.nil?
        response.stream.write "data: #{resp.to_json}\n\n"
      else
        fails_array << h
        resp[:result] = false
        resp[:last_row] = index + 1
        response.stream.write "data: #{resp.to_json}\n\n"
      end
      index += 1
    end
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
                                          'total' => base_json.length,
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
                                        'total' => base_json.length,
                                        'last_row' => base_json.length,
                                        'hash' => params[:path],
                                        'id' => params[:ud],
                                        'fails_array' => fails_array
    ].to_json}\n\n"


  else
    resp[:last_row] = 0
    resp[:result] = false
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
