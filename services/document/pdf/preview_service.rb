# frozen_string_literal: true

require 'pdf/reader'
require 'open3'

module Document
  module Pdf
    # Rasterizes a single PDF page to PNG via poppler's pdftoppm, so a
    # caller can overlay the field rects from ExtractFieldsService on top
    # (variant B of the field map preview: no boxes baked in server-side).
    class PreviewService
      DEFAULT_DPI = 150

      class InvalidPageError < StandardError; end

      def initialize(params, tempfile)
        @file_path = params[:file][:tempfile].path
        @page = params[:page] || 1
        @dpi = params[:dpi] || DEFAULT_DPI
        @tempfile_path = tempfile.path
      end

      def call
        validate_page!

        prefix = @tempfile_path.sub(/\.png$/, '')
        _stdout, stderr, status = Open3.capture3(
          'pdftoppm', '-png', '-r', @dpi.to_s, '-f', @page.to_s, '-l', @page.to_s,
          '-singlefile', @file_path, prefix
        )
        raise "pdftoppm failed: #{stderr}" unless status.success?

        "#{prefix}.png"
      end

      private

      def validate_page!
        page_count = PDF::Reader.new(@file_path).page_count
        return if @page.between?(1, page_count)

        raise InvalidPageError, "page #{@page} out of range (1..#{page_count})"
      end
    end
  end
end
