# frozen_string_literal: true

require 'pdf_forms'
require 'json'
require 'tempfile'

require_relative 'decrypt_service'
require_relative 'overlay_fill_service'
require_relative 'mask_sanitizer_service'
require_relative 'font_sanitizer_service'

module Document
  module Pdf
    # Fills AcroForm text fields with real values via pdftk, then optionally
    # stamps free-text at explicit coordinates (see OverlayFillService) for
    # PDFs with no, or incomplete, AcroForm fields. Output stays editable by
    # default (flatten: false) so the user can still touch it up.
    class FillService
      REPLACEMENT_FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'

      def initialize(params, tempfile)
        # Tempfile objects returned alongside each intermediate path must
        # stay referenced for the lifetime of this service - otherwise GC
        # can unlink one mid-pipeline (Tempfile's finalizer) before pdftk/
        # soffice gets a chance to read it. See DecryptService.
        @retained_tempfiles = []

        template_path, decrypted = DecryptService.call(params[:file][:tempfile].path)
        @retained_tempfiles << decrypted

        template_path, masked = MaskSanitizerService.call(template_path)
        @retained_tempfiles << masked

        @template_path, fonts_fixed = FontSanitizerService.call(template_path)
        @retained_tempfiles << fonts_fixed

        @tempfile_path = tempfile.path
        @values = parse_values(params[:values])
        @positions = params[:positions]
        @flatten = params[:flatten] ? true : false
      end

      def call
        source = @template_path

        if @values.any? || @flatten
          fill_tempfile = Tempfile.new(%w[filled .pdf]) if @positions
          @retained_tempfiles << fill_tempfile
          fill_target = fill_tempfile ? fill_tempfile.path : @tempfile_path

          pdftk = PdfForms.new(data_format: 'FdfHex')
          pdftk.fill_form(source, fill_target, @values, need_appearances: false, flatten: @flatten,
                                                         replacement_font: REPLACEMENT_FONT)
          source = fill_target
        end

        return source unless @positions

        OverlayFillService.new(source, @positions, @tempfile_path).call
      end

      private

      def parse_values(values)
        values = JSON.parse(values) if values.is_a?(String)
        (values || {}).transform_keys(&:to_s)
      end
    end
  end
end
