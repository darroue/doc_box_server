require "rqrcode"

module QrCode
  class PaymentService
    def call(iban:, variable_symbol:, specific_symbol:, amount:, message:, currency:, payment_date:)
      data = {
        ACC: iban,
        "X-VS": variable_symbol,
        "X-SS": specific_symbol,
        AM: amount,
        MSG: message,
        DT: payment_date,
        CC: currency
      }.reject(& -> (k,v) { v.nil? || v.to_s.strip == "" })

      qrcode = RQRCode::QRCode.new([
        'SPD',
        '1.0',
        data.map(& ->(k, v) { "#{k}:#{v}" })
      ].flatten.join('*'))
    end
  end
end
