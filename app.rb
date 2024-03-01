require 'grape'
require 'grape-swagger'
require 'byebug'
require_relative 'services/qr_code/payment_service'
require_relative 'services/qr_code/text_service'

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
        File.open(tmp_file, "wb") do |file|
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
        requires :variable_symbol, type: Integer, regexp: /^\d{10}$/
        requires :specific_symbol, type: Integer, regexp: /^\d{10}$/
        requires :constant_symbol, type: Integer, regexp: /^\d{10}$/
        requires :amount, type: Integer, allow_blank: false, regexp: /^\d{1,7}(\.\d{1,2}){0,1}$/
        requires :message, type: String, regexp: /^[A-Z0-9\s]{0,60}$/
        requires :currency, type: String, default: "CZK", allow_blank: false, regexp: /^[A-Z]{3}$/
        requires :payment_date, type: Integer, regexp: /^\d{8}$/
      end
      desc "Creates Payment QRCode in PNG format based on given params"
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
  end
end
