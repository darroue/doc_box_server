# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require 'open3'

require_relative '../../../services/document/pdf/fill_service'

module Document
  module Pdf
    # Regression test for the e-signature flow: signing calls FillService with
    # an image position (to stamp the signature) but no new AcroForm `values`
    # - only `flatten: true`, to bake in whatever values the earlier
    # generation step already filled and make the form non-editable. The
    # pdftk fill_form call (the only step that honours `flatten:`) used to be
    # gated on `@values.any?`, so a values-less flatten request silently did
    # nothing and the "flattened" PDF still had live, editable form fields.
    class FillServiceTest < Minitest::Test
      TEMPLATE_PATH = File.expand_path('../../fixtures/acroform_template.pdf', __dir__)

      def setup
        @output = Tempfile.new(%w[fill_service_test .pdf])
      end

      def teardown
        @output.close!
      end

      def test_template_has_acroform_fields_before_flattening
        refute_empty field_names(TEMPLATE_PATH), 'fixture is expected to ship with real AcroForm fields'
      end

      def test_flatten_true_with_no_values_still_removes_form_fields
        result_path = call_service(values: {}, flatten: true)

        assert_empty field_names(result_path),
                     'flatten: true must bake in/remove AcroForm fields even when no new values are supplied'
      end

      def test_flatten_false_with_no_values_leaves_form_fields_editable
        result_path = call_service(values: {}, flatten: false)

        refute_empty field_names(result_path), 'flatten: false must leave the AcroForm fields as-is'
      end

      def test_flatten_true_also_stamps_the_signature_overlay
        skip 'soffice (LibreOffice) not installed - required by OverlayFillService' unless soffice_available?

        positions = [{ page: 1, x: 50, y: 50, type: 'image', image: sample_png_base64, width: 40, height: 20 }]

        result_path = call_service(values: {}, flatten: true, positions: positions)

        assert_empty field_names(result_path)
        assert File.exist?(result_path)
        assert_operator File.size(result_path), :>, 0
      end

      private

      def call_service(values:, flatten:, positions: nil)
        params = {
          file: { tempfile: File.open(TEMPLATE_PATH, 'rb') },
          values: values,
          flatten: flatten
        }
        params[:positions] = positions if positions

        FillService.new(params, @output).call
      end

      def soffice_available?
        _stdout, _stderr, status = Open3.capture3('which', 'soffice')
        status.success?
      end

      def field_names(pdf_path)
        stdout, _stderr, status = Open3.capture3('pdftk', pdf_path, 'dump_data_fields')
        raise "pdftk dump_data_fields failed for #{pdf_path}" unless status.success?

        stdout.scan(/^FieldName: (.*)$/).flatten
      end

      def sample_png_base64
        require 'chunky_png'
        require 'base64'
        png = ChunkyPNG::Image.new(20, 10, ChunkyPNG::Color.rgba(0, 0, 0, 255))
        Base64.strict_encode64(png.to_blob)
      end
    end
  end
end
