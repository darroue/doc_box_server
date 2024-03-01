require "rqrcode"

module QrCode
  class TextService
    def call(text:)
      RQRCode::QRCode.new(text)
    end
  end
end
