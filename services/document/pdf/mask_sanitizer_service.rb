# frozen_string_literal: true

require 'tempfile'
require 'open3'

module Document
  module Pdf
    # Some PDF producers (seen in an Adobe InDesign export) emit Image
    # XObjects with a color-key /Mask (a plain array of component ranges)
    # instead of a stencil mask stream. That's valid PDF, but several print
    # drivers/RIPs only understand the stream form and abort with an
    # "invalid type" dictionary error on the /Mask entry when printing.
    # Stripping the array turns the masked color opaque instead of
    # transparent; for the real-world case that triggered this (a logo
    # whose masked color already matched the surrounding page background)
    # that produced no visible difference.
    class MaskSanitizerService
      MASK_REF = /\/Mask (\d+) 0 R/.freeze

      # Returns [path, tempfile] - see DecryptService for why the Tempfile
      # object itself must be kept alive by the caller alongside the path.
      def self.call(pdf_path)
        new(pdf_path).call
      end

      def initialize(pdf_path)
        @pdf_path = pdf_path
      end

      def call
        qdf = to_qdf(@pdf_path)
        return [@pdf_path, nil] unless qdf

        sanitized = strip_array_masks(qdf)
        return [@pdf_path, nil] if sanitized == qdf

        rebuild(sanitized)
      end

      private

      def to_qdf(path)
        Tempfile.create(['sanitize', '.qdf']) do |out|
          _out, _err, status = Open3.capture3('qpdf', '--qdf', '--object-streams=disable', path, out.path)
          return nil unless status.success?

          return File.binread(out.path)
        end
      end

      def strip_array_masks(qdf)
        qdf.gsub(MASK_REF) { |match| array_object?(qdf, Regexp.last_match(1)) ? '' : match }
      end

      def array_object?(qdf, obj_id)
        qdf.match?(/\n#{obj_id} 0 obj\n\[/)
      end

      def rebuild(qdf_content)
        Tempfile.create(['sanitized_in', '.qdf']) do |qdf_file|
          qdf_file.binmode
          qdf_file.write(qdf_content)
          qdf_file.flush

          out = Tempfile.new(['sanitized', '.pdf'])
          _out, _err, status = Open3.capture3('qpdf', qdf_file.path, out.path)
          return [@pdf_path, nil] unless status.success? || status.exitstatus == 3

          [out.path, out]
        end
      end
    end
  end
end
