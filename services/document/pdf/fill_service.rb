# frozen_string_literal: true

require 'pdf_forms'
require 'json'

module Document
  module Pdf
    # Fills AcroForm text fields with real values via pdftk. Output stays
    # editable by default (flatten: false) so the user can still touch it up.
    class FillService
      def initialize(params, tempfile)
        @template_path = params[:file][:tempfile].path
        @tempfile_path = tempfile.path
        @values = parse_values(params[:values])
        @flatten = params[:flatten] ? true : false
      end

      def call
        PdfForms.new.fill_form(@template_path, @tempfile_path, @values, need_appearances: true, flatten: @flatten)

        @tempfile_path
      end

      private

      def parse_values(values)
        values = JSON.parse(values) if values.is_a?(String)
        (values || {}).transform_keys(&:to_s)
      end
    end
  end
end
