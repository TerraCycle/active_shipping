require 'rexml/document'

module ActiveShipping
  # Implements the ActiveShipping::DHL Carrier
  class DHL < Carrier
    TEST_URL = 'https://xmlpitest-ea.dhl.com/XMLShippingServlet'
    LIVE_URL = 'https://xmlpi-ea.dhl.com/XMLShippingServlet'

    PAYMENT_TYPES = {
      shipper: 'S',
      receiver: 'R',
      third_party: 'T'
    }.freeze

    def requirements
      %i[login password account_number return_service global_product_code
         local_product_code door_to]
    end

    def generate_label(origin, destination, packages, options = {})
      options = @options.update(options)
      packages = Array(packages)
      label_request = build_label_request(origin, destination, packages, options)

      response = commit(save_request(label_request), options[:test])
      parse_label_response(response)
    end

    def parse_label_response(response)
      xml = begin
        REXML::Document.new(response)
      rescue REXML::ParseException
        REXML::Document.new(response.force_encoding('ISO-8859-1').encode('UTF-8'))
      end

      success = response_success?(xml)
      raise response_message(xml) unless success

      tracking_number = xml.get_text('//AirwayBillNumber').value
      image_data = Base64.decode64(xml.get_text('//LabelImage/OutputImage').to_s)

      label = Label.new(
        tracking_number,
        image_data
      )

      pieces = xml.get_elements('//Pieces/Piece')
      label.plates = pieces.collect do |piece|
        piece.get_text('DataIdentifier').to_s + piece.get_text('LicensePlate').to_s
      end

      hsh = begin
        Hash.from_xml(response)
      rescue REXML::ParseException
        Hash.from_xml(response.force_encoding('ISO-8859-1').encode('UTF-8'))
      end

      LabelResponse.new(
        success, 'DHL label created', hsh,
        labels: [label]
      )
    end

    def response_success?(document)
      document.get_text('//Note/ActionNote').try(:value) == 'Success'
    end

    def response_message(document)
      document.get_text('//ConditionData').value
    end

    protected

    def imperial?
      false # DHL_Countries_With_Imperial_Units.include? country_code.strip.upcase
    end

    def build_label_request(origin, destination, packages, options)
      builder = Nokogiri::XML::Builder.new do |xml|
        xml.ShipmentValidateRequestEA('xmlns:req' => 'http://www.dhl.com', 'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance', 'xsi:schemaLocation' => 'http://www.dhl.com ship-val-req_EA.xsd') do
          xml.Request do
            xml.ServiceHeader do
              xml.MessageTime Time.current.iso8601
              xml.MessageReference SecureRandom.uuid.delete('-').upcase
              # The Message Reference element should contain a unique reference to the message,
              # so that trace of a particular message can easily be carried out.
              # It must be of minimum length of 28 and maximum 32.
              # The value can be decided by the customer.
              xml.SiteID @options[:login]
              xml.Password @options[:password]
            end
          end
          xml.NewShipper 'N'
          xml.LanguageCode 'en'
          xml.PiecesEnabled 'Y'
          xml.Billing do
            xml.ShipperAccountNumber @options[:account_number]
            xml.ShippingPaymentType PAYMENT_TYPES[(@options[:return_service] ? :receiver : :shipper)]
            xml.BillingAccountNumber @options[:account_number] if @options[:return_service]
          end
          xml.Consignee do # destination
            xml.CompanyName destination.company_name[0...35]
            xml.AddressLine destination.address1[0...35]
            xml.AddressLine destination.address2[0...35] if destination.address2.present?
            xml.AddressLine destination.address3[0...35] if destination.address3.present?
            xml.City destination.city[0...35]
            xml.Division destination.region[0...35] if destination.region.present?
            xml.PostalCode destination.zip
            xml.CountryCode destination.country_code
            xml.CountryName destination.country.name
            xml.Contact do
              xml.PersonName destination.name[0...35]
              xml.PhoneNumber destination.phone.present? ? destination.phone[0...25] : 'NA'
            end
          end
          xml.Reference do
            xml.ReferenceID options[:reference1][0...35]
          end
          xml.ShipmentDetails do # optional
            xml.NumberOfPieces packages.count
            xml.CurrencyCode @options[:currency]
            total_weight = 0
            xml.Pieces do
              packages.each.with_index do |pkg, package_number|
                xml.Piece do
                  xml.PieceID package_number
                  # xml.PackageType 'CP' # custom packaging # optional
                  xml.Weight imperial? ? pkg.lbs : pkg.kgs.round(3)
                  total_weight += imperial? ? pkg.lbs : pkg.kgs
                  xml.Depth imperial? ? pkg.inches(:length) : pkg.cm(:length).round
                  xml.Width imperial? ? pkg.inches(:width) : pkg.cm(:width).round
                  xml.Height imperial? ? pkg.inches(:height) : pkg.cm(:height).round
                end
              end
            end
            xml.PackageType 'CP' # custom packaging
            xml.Weight total_weight.round(3)
            xml.DimensionUnit imperial? ? 'I' : 'C'
            xml.WeightUnit imperial? ? 'L' : 'K'
            xml.GlobalProductCode @options[:global_product_code]
            xml.LocalProductCode @options[:local_product_code]
            xml.DoorTo @options[:door_to]
            xml.Date Date.tomorrow.iso8601
            xml.Contents @options[:brigade_unit_name]
          end
          xml.Shipper do
            xml.ShipperID @options[:account_number] # as per instruction from Lionel Brendlin
            xml.CompanyName origin.company_name[0...35]
            xml.RegisteredAccount @options[:account_number]
            xml.AddressLine origin.address1[0...35]
            xml.AddressLine origin.address2[0...35] if origin.address2.present?
            xml.AddressLine origin.address3[0...35] if origin.address3.present?
            xml.City origin.city[0...35]
            xml.Division origin.region[0...35] if origin.region.present?
            xml.PostalCode origin.zip
            xml.CountryCode origin.country_code
            xml.CountryName origin.country.name
            xml.Contact do
              xml.PersonName origin.name[0...35]
              xml.PhoneNumber origin.phone.present? ? origin.phone[0...25] : 'NA'
            end
          end
          xml.SpecialService do
            # label expiration: PT = 3 months, PU = 6 months, PV = 12 months, PW = 24 months
            xml.SpecialServiceType 'PV'
          end
          xml.EProcShip 'N'
          xml.LabelImageFormat 'PDF'
          xml.RequestArchiveDoc 'N'
        end
      end

      builder.to_xml
    end

    def commit(request, test = false)
      ssl_post(test ? TEST_URL : LIVE_URL, request.gsub('\n', ''))
    end
  end
end
