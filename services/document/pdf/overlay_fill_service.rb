# frozen_string_literal: true

require 'pdf/reader'
require 'pdf_forms'
require 'open3'
require 'zip'
require 'cgi'
require 'tmpdir'
require 'json'

module Document
  module Pdf
    # Stamps free text at explicit PDF-point coordinates onto a template PDF
    # that has no (or incomplete) AcroForm fields to fill via FillService.
    #
    # No PDF-writing gem is used (hexapdf is AGPL, prawn pulls in font
    # embedding we don't need): a throwaway ODF text document is built by
    # hand, sized page-for-page to the template, with one absolutely
    # positioned draw:frame per requested position. LibreOffice (already
    # used elsewhere in this app for ODT->PDF conversion) renders it to a
    # same-page-count overlay PDF, which pdftk then merges onto the
    # template via `multistamp` - both tools already in the Docker image.
    class OverlayFillService
      PT_TO_CM = 2.54 / 72.0
      DEFAULT_FONT_SIZE = 10.0
      FONT_NAME = 'DejaVu Sans'

      class OutOfRangeError < StandardError; end

      def initialize(template_path, positions, output_path)
        @template_path = template_path
        @positions = parse_positions(positions)
        @output_path = output_path
      end

      def call
        return @template_path if @positions.empty?

        page_sizes = PDF::Reader.new(@template_path).pages.map { |page| page_size(page) }
        by_page = @positions.group_by { |p| p[:page] }
        validate_pages!(by_page.keys, page_sizes.size)

        Dir.mktmpdir do |dir|
          odt_path = build_odt(File.join(dir, 'overlay.odt'), page_sizes, by_page)
          overlay_pdf_path = convert_to_pdf(odt_path, dir)

          PdfForms.new.multistamp(@template_path, overlay_pdf_path, @output_path)
        end

        @output_path
      end

      private

      def parse_positions(positions)
        positions = JSON.parse(positions) if positions.is_a?(String)
        Array(positions).map { |p| normalize(p) }
      end

      def normalize(position)
        p = position.transform_keys(&:to_s)
        {
          page: Integer(p.fetch('page')),
          x: Float(p.fetch('x')),
          y: Float(p.fetch('y')),
          text: p.fetch('text').to_s,
          size: p['size'] ? Float(p['size']) : DEFAULT_FONT_SIZE
        }
      end

      def page_size(page)
        llx, lly, urx, ury = page.attributes[:MediaBox].map(&:to_f)
        [urx - llx, ury - lly]
      end

      def validate_pages!(pages, page_count)
        out_of_range = pages.reject { |page| page.between?(1, page_count) }
        return if out_of_range.empty?

        raise OutOfRangeError, "position page(s) #{out_of_range.sort.join(', ')} out of range (1..#{page_count})"
      end

      def build_odt(odt_path, page_sizes, by_page)
        Zip::OutputStream.open(odt_path) do |zos|
          zos.put_next_entry('mimetype', nil, nil, Zip::Entry::STORED)
          zos.write 'application/vnd.oasis.opendocument.text'

          zos.put_next_entry('META-INF/manifest.xml')
          zos.write manifest_xml

          zos.put_next_entry('styles.xml')
          zos.write styles_xml(page_sizes)

          zos.put_next_entry('content.xml')
          zos.write content_xml(page_sizes, by_page)
        end

        odt_path
      end

      def convert_to_pdf(odt_path, dir)
        profile_dir = File.join(dir, 'libreoffice-profile')
        _stdout, stderr, status = Open3.capture3(
          'soffice', '--headless', "-env:UserInstallation=file://#{profile_dir}",
          '--convert-to', 'pdf', '--outdir', dir, odt_path
        )
        raise "soffice conversion failed: #{stderr}" unless status.success?

        odt_path.sub(/\.odt\z/, '.pdf')
      end

      def manifest_xml
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
           <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.text"/>
           <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
           <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
          </manifest:manifest>
        XML
      end

      def styles_xml(page_sizes)
        layouts = master_page_names(page_sizes)

        page_layout_xml = layouts.map do |(width, height), name|
          <<~XML
            <style:page-layout style:name="PL_#{name}">
              <style:page-layout-properties fo:page-width="#{cm(width)}" fo:page-height="#{cm(height)}" fo:margin="0cm"/>
            </style:page-layout>
          XML
        end.join

        master_page_xml = layouts.map do |_size, name|
          %(<style:master-page style:name="#{name}" style:page-layout-name="PL_#{name}"/>\n)
        end.join

        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
            xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
            office:version="1.2">
            <office:automatic-styles>
          #{page_layout_xml}
            </office:automatic-styles>
            <office:master-styles>
          #{master_page_xml}
            </office:master-styles>
          </office:document-styles>
        XML
      end

      def content_xml(page_sizes, by_page)
        layouts = master_page_names(page_sizes)
        sizes = @positions.map { |p| p[:size] }.uniq

        font_style_xml = sizes.map do |size|
          <<~XML
            <style:style style:name="#{font_style_name(size)}" style:family="paragraph">
              <style:paragraph-properties fo:wrap-option="no-wrap"/>
              <style:text-properties style:font-name="#{FONT_NAME}" fo:font-size="#{size}pt"/>
            </style:style>
          XML
        end.join

        page_style_xml = page_sizes.each_index.map do |i|
          master = layouts.fetch(page_sizes[i])
          break_attr = i.zero? ? '' : ' fo:break-before="page"'
          <<~XML
            <style:style style:name="#{page_style_name(i)}" style:family="paragraph" style:master-page-name="#{master}">
              <style:paragraph-properties#{break_attr}/>
            </style:style>
          XML
        end.join

        body_xml = page_sizes.each_index.map do |i|
          frames = (by_page[i + 1] || []).map { |p| frame_xml(p, page_sizes[i], i + 1) }.join
          %(<text:p text:style-name="#{page_style_name(i)}">#{frames}</text:p>\n)
        end.join

        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
            xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
            xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
            xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
            office:version="1.2">
            <office:font-face-decls>
              <style:font-face style:name="#{FONT_NAME}" svg:font-family="&quot;#{FONT_NAME}&quot;"/>
            </office:font-face-decls>
            <office:automatic-styles>
              <style:style style:name="FR" style:family="graphic">
                <style:graphic-properties draw:stroke="none" draw:fill="none" fo:padding="0cm" style:wrap="none" style:vertical-pos="from-top" style:horizontal-pos="from-left"/>
              </style:style>
          #{font_style_xml}
          #{page_style_xml}
            </office:automatic-styles>
            <office:body>
              <office:text>
          #{body_xml}
              </office:text>
            </office:body>
          </office:document-content>
        XML
      end

      def frame_xml(position, page_size, page_number)
        page_width, page_height = page_size
        height_pt = position[:size] * 1.5
        width_pt = [page_width - position[:x], position[:size] * 4].max
        top_pt = [page_height - position[:y] - height_pt, 0].max

        <<~XML
          <draw:frame draw:style-name="FR" svg:width="#{cm(width_pt)}" svg:height="#{cm(height_pt)}" svg:x="#{cm(position[:x])}" svg:y="#{cm(top_pt)}" text:anchor-type="page" text:anchor-page-number="#{page_number}">
            <draw:text-box>
              <text:p text:style-name="#{font_style_name(position[:size])}">#{escape(position[:text])}</text:p>
            </draw:text-box>
          </draw:frame>
        XML
      end

      def master_page_names(page_sizes)
        page_sizes.uniq.each_with_index.to_h { |size, i| [size, "MP#{i}"] }
      end

      def page_style_name(index)
        "PP#{index}"
      end

      def font_style_name(size)
        "FS#{(size * 10).round}"
      end

      def cm(points)
        format('%.4fcm', points * PT_TO_CM)
      end

      def escape(text)
        CGI.escapeHTML(text).gsub("\n", '<text:line-break/>')
      end
    end
  end
end
