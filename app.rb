require 'grape'
require 'byebug'
require_relative 'services/qr_code/payment_service'

module DocBox
  class API < Grape::API
    version 'v1'
    prefix 'api'
    format :json

    resource :qrcode do
      params do
        requires :iban, type: String
        requires :variable_symbol, type: Integer
        requires :specific_symbol, type: Integer
        requires :amount, type: Integer
        requires :message, type: String
        requires :currency, type: String, values: %w(CZK)
        requires :payment_date, type: String
        optional :border, type: Integer, default: 4
        optional :size, type: Integer, default: 120
      end
      post :payment do
        content_type 'image/png'

        qr_code = QrCode::PaymentService.new.call(**declared(params, include_missing: true).symbolize_keys.except(:border, :size))
        tmp_file = Tempfile.new
        File.open(tmp_file, "wb") do |file|
          file.write(qr_code.as_png(border_modules: params[:border], size: params[:size]))
        end

        sendfile tmp_file.path
      end
    end
  end
end
