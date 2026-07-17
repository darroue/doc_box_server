require_relative 'services/services'

require 'grape'

module DocBox
  class API < Grape::API
    version 'v1'
    prefix 'api'

    format :json

    helpers do
      def respond_qr(service)
        content_type 'image/png'

        qr_code = service.new.call(**declared(params, include_missing: true).symbolize_keys.except(:border, :size))

        tmp_file = Tempfile.new
        File.open(tmp_file, 'wb') do |file|
          file.write(qr_code.as_png(border_modules: params[:border], size: params[:size]))
        end

        sendfile tmp_file.path
      end
    end

    params do
      optional :border, type: Integer, default: 4, regexp: /^\d{1,4}$/
      optional :size, type: Integer, default: 120, regexp: /^\d{1,4}$/
    end
    resource :qrcode do
      params do
        requires :iban, type: String, allow_blank: false, regexp: /^[A-Z0-9]{15,34}$/
        requires :variable_symbol, type: Integer, regexp: /^\d{0,10}$/
        requires :specific_symbol, type: Integer, regexp: /^\d{0,10}$/
        requires :constant_symbol, type: Integer, regexp: /^\d{0,10}$/
        requires :amount, type: Integer, allow_blank: false, regexp: /^\d{1,7}(\.\d{1,2}){0,1}$/
        requires :message, type: String, regexp: %r{^[A-Z0-9\s\-$%*+-.,/:]{0,60}$}
        requires :currency, type: String, default: 'CZK', allow_blank: false, regexp: /^[A-Z]{3}$/
        requires :payment_date, type: Integer, regexp: /^\d{8}$/
      end
      desc 'Creates Payment QRCode in PNG format based on given params'
      post :payment do
        respond_qr(QrCode::PaymentService)
      end

      params do
        requires :text, type: String, allow_blank: false
      end
      post :text do
        respond_qr(QrCode::TextService)
      end
    end

    resource :document do
      resource :odt do
        params do
          requires :data, type: Hash, allow_blank: false
          requires :template, type: File, allow_blank: false
          optional :files, type: Array[File]
          optional :filename, type: String
        end
        post :fill do
          content_type 'application/vnd.oasis.opendocument.text'

          filename = declared(params)[:filename] || declared(params)[:template][:filename]
          service = Document::FillService.new(declared(params), Tempfile.new(filename))

          sendfile service.call
        end

        params do
          requires :file, type: File, allow_blank: false
        end
        post :convert_to_pdf do
          content_type 'application/pdf'

          sendfile Document::ConvertToPdfService.new(declared(params)).call
        end
      end

      resource :pdf do
        params do
          requires :file, type: File, allow_blank: false
        end
        desc 'Extracts AcroForm text fields (name, page, rect in PDF points) from a PDF template'
        post :fields do
          Document::Pdf::ExtractFieldsService.new(declared(params)).call
        end

        params do
          requires :file, type: File, allow_blank: false
          optional :values, type: Hash
          optional :positions, type: Array
          optional :flatten, type: Boolean, default: false
        end
        desc 'Fills AcroForm text fields with given values and/or stamps text at given ' \
             '[{page, x, y, text, size}] coordinates, and returns the resulting PDF'
        post :fill do
          content_type 'application/pdf'

          filename = declared(params)[:file][:filename]
          service = Document::Pdf::FillService.new(declared(params), Tempfile.new(filename))

          sendfile service.call
        end

        params do
          requires :file, type: File, allow_blank: false
          optional :page, type: Integer, default: 1
          optional :dpi, type: Integer, default: 150
        end
        desc 'Rasterizes one PDF page to PNG, for overlaying field rects from /fields client-side'
        post :preview do
          content_type 'image/png'

          service = Document::Pdf::PreviewService.new(declared(params), Tempfile.new(%w[preview .png]))

          sendfile service.call
        end
      end
    end
  end
end
