# frozen_string_literal: true

require 'minitest/autorun'
require 'pdf/reader'
require 'base64'
require 'tempfile'
require 'tmpdir'
require 'open3'
require 'chunky_png'

require_relative '../../../services/document/pdf/overlay_fill_service'

module Document
  module Pdf
    # Exercises OverlayFillService end to end (real LibreOffice conversion +
    # real pdftk multistamp) against a tiny 2-page fixture PDF. Covers both
    # the pre-existing text-stamp behaviour (regression) and the new
    # image-stamp behaviour added for e-signatures.
    #
    # NOTE on assertion strategy: `page.xobjects` (the page's /Resources
    # dict) is NOT a reliable way to check "is this image actually drawn on
    # this page" - both LibreOffice's PDF export and pdftk's multistamp wrap
    # each merged page in its own Form XObject and declare it in every
    # page's Resources dictionary, so a name can be *listed* on a page that
    # never actually paints it. What matters is what's visually rendered, so
    # image-placement assertions here rasterize pages with pdftoppm (already
    # a runtime dependency of PreviewService/the Docker image) and compare
    # pixels rather than inspecting the PDF object graph.
    class OverlayFillServiceTest < Minitest::Test
      TEMPLATE_PATH = File.expand_path('../../fixtures/two_page_template.pdf', __dir__)

      def setup
        @output = Tempfile.new(%w[overlay_test .pdf])
      end

      def teardown
        @output.close!
      end

      def test_text_position_stamps_without_changing_page_count
        positions = [{ page: 1, x: 50, y: 700, text: 'Hello World', size: 12 }]

        result_path = OverlayFillService.new(TEMPLATE_PATH, positions, @output.path).call

        reader = PDF::Reader.new(result_path)
        assert_equal 2, reader.page_count
        assert_operator File.size(result_path), :>, 0
      end

      def test_text_position_without_type_key_defaults_to_text_for_backward_compatibility
        positions = [{ 'page' => 1, 'x' => 50, 'y' => 700, 'text' => 'No type key', 'size' => 12 }]

        result_path = OverlayFillService.new(TEMPLATE_PATH, positions, @output.path).call

        assert_equal 2, PDF::Reader.new(result_path).page_count
      end

      def test_image_position_is_embedded_in_the_pdf_object_graph
        positions = [
          { page: 2, x: 100, y: 100, type: 'image', image: sample_png_base64, width: 80, height: 40 }
        ]

        result_path = OverlayFillService.new(TEMPLATE_PATH, positions, @output.path).call

        reader = PDF::Reader.new(result_path)
        assert_equal 2, reader.page_count
        assert embedded_image?(reader, width: 20, height: 10),
               'expected a Width=20/Height=10 Image XObject to be embedded somewhere in the PDF'
      end

      def test_image_position_is_only_visually_painted_on_its_own_page
        positions = [
          { page: 2, x: 100, y: 100, type: 'image', image: sample_png_base64, width: 80, height: 40 }
        ]

        result_path = OverlayFillService.new(TEMPLATE_PATH, positions, @output.path).call

        # Page 1 has no position stamped on it, so it must render pixel-identical
        # to the original template - no bleed-through from page 2's image.
        assert_equal render_page(TEMPLATE_PATH, 1), render_page(result_path, 1),
                     'page without an image position should render identically to the unstamped template'

        # Page 2 has the image stamped on it, so its pixels must differ from the original.
        refute_equal render_page(TEMPLATE_PATH, 2), render_page(result_path, 2),
                     'page with an image position should render differently from the unstamped template'
      end

      def test_mixed_text_and_image_positions_on_the_same_document
        positions = [
          { page: 1, x: 50, y: 700, text: 'Signed by Jane Doe', size: 10 },
          { page: 2, x: 100, y: 100, type: 'image', image: sample_png_base64, width: 80, height: 40 }
        ]

        result_path = OverlayFillService.new(TEMPLATE_PATH, positions, @output.path).call

        reader = PDF::Reader.new(result_path)
        assert_equal 2, reader.page_count
        refute_equal render_page(TEMPLATE_PATH, 1), render_page(result_path, 1)
        refute_equal render_page(TEMPLATE_PATH, 2), render_page(result_path, 2)
      end

      def test_multiple_image_positions_on_the_same_page_both_get_embedded
        positions = [
          { page: 1, x: 40, y: 600, type: 'image', width: 50, height: 20,
            image: sample_png_base64(color: [200, 30, 30, 255]) },
          { page: 1, x: 40, y: 500, type: 'image', width: 50, height: 20,
            image: sample_png_base64(color: [30, 30, 200, 255]) }
        ]

        result_path = OverlayFillService.new(TEMPLATE_PATH, positions, @output.path).call

        reader = PDF::Reader.new(result_path)
        refute_equal render_page(TEMPLATE_PATH, 1), render_page(result_path, 1)
        # Both source PNGs are 20x10px (the frame's width/height above is the
        # *display* size in PDF points, not the embedded raster's pixel size).
        assert_equal 2, images_matching(reader, width: 20, height: 10).size,
                     'expected two distinct embedded pictures (Pictures/sig_0.png and Pictures/sig_1.png)'
      end

      def test_unknown_position_type_raises
        assert_raises(OverlayFillService::InvalidPositionError) do
          OverlayFillService.new(TEMPLATE_PATH, [{ page: 1, x: 0, y: 0, type: 'bogus' }], @output.path)
        end
      end

      def test_out_of_range_page_raises
        assert_raises(OverlayFillService::OutOfRangeError) do
          positions = [{ page: 99, x: 0, y: 0, type: 'image', image: sample_png_base64, width: 10, height: 10 }]
          OverlayFillService.new(TEMPLATE_PATH, positions, @output.path).call
        end
      end

      private

      # Scans every indirect object in the PDF for an Image XObject with the
      # given pixel dimensions - proof the PNG bytes were genuinely embedded
      # (not just referenced), independent of which page(s) declare it.
      def embedded_image?(reader, width:, height:)
        images_matching(reader, width: width, height: height).any?
      end

      def images_matching(reader, width:, height:)
        reader.objects.select do |_id, obj|
          obj.is_a?(PDF::Reader::Stream) &&
            obj.hash[:Subtype] == :Image &&
            obj.hash[:Width] == width &&
            obj.hash[:Height] == height
        end
      end

      def render_page(pdf_path, page_number)
        Dir.mktmpdir do |dir|
          prefix = File.join(dir, 'page')
          _stdout, stderr, status = Open3.capture3(
            'pdftoppm', '-png', '-r', '72', '-f', page_number.to_s, '-l', page_number.to_s,
            '-singlefile', pdf_path, prefix
          )
          raise "pdftoppm failed: #{stderr}" unless status.success?

          File.binread("#{prefix}.png")
        end
      end

      def sample_png_base64(color: [200, 30, 30, 255])
        png = ChunkyPNG::Image.new(20, 10, ChunkyPNG::Color.rgba(*color))
        Base64.strict_encode64(png.to_blob)
      end
    end
  end
end
