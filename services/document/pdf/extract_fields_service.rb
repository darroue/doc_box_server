# frozen_string_literal: true

require 'pdf/reader'

module Document
  module Pdf
    # Reads AcroForm text fields (/FT /Tx) out of a PDF, including their
    # position (/Rect, in PDF points) so a caller can render a field map
    # overlay on top of a rasterized page.
    class ExtractFieldsService
      TEXT_FIELD_TYPE = :Tx

      def initialize(params)
        @file_path = params[:file][:tempfile].path
      end

      def call
        reader = PDF::Reader.new(@file_path)

        fields = reader.pages.each_with_index.flat_map do |page, index|
          fields_for_page(page, index + 1)
        end

        { page_count: reader.page_count, fields: fields }
      end

      private

      def fields_for_page(page, page_number)
        objects = page.objects
        origin_x, origin_y, page_size = page_geometry(page, objects)

        annotations(page).filter_map do |widget|
          next unless field_type(widget, objects) == TEXT_FIELD_TYPE

          field_for_widget(widget, objects, page_number, origin_x, origin_y, page_size)
        end
      end

      def page_geometry(page, objects)
        llx, lly, urx, ury = objects.deref!(page.attributes[:MediaBox]).map(&:to_f)
        [llx, lly, [urx - llx, ury - lly]]
      end

      def field_for_widget(widget, objects, page_number, origin_x, origin_y, page_size)
        name = field_name(widget, objects)
        rect = objects.deref!(widget[:Rect])
        return if name.nil? || name.empty? || rect.nil? || rect.size != 4

        x0, y0, x1, y1 = rect.map(&:to_f)
        {
          name: name,
          type: 'Tx',
          page: page_number,
          rect: [x0 - origin_x, y0 - origin_y, x1 - origin_x, y1 - origin_y],
          page_size: page_size
        }
      end

      def annotations(page)
        objects = page.objects
        Array(objects.deref!(page.attributes[:Annots])).filter_map do |ref|
          widget = objects.deref!(ref)
          widget if widget.is_a?(Hash) && objects.deref!(widget[:Subtype]) == :Widget
        end
      end

      # /FT can live on the widget itself, or be inherited from a /Parent
      # field (common for grouped/child widgets, e.g. "pole 25.0").
      def field_type(widget, objects, seen = [])
        walk_up(widget, objects, seen) { |dict| objects.deref!(dict[:FT]) }
      end

      def field_name(widget, objects, seen = [])
        walk_up(widget, objects, seen) { |dict| objects.deref!(dict[:T])&.to_s }
      end

      def walk_up(dict, objects, seen, &block)
        return nil if dict.nil? || seen.include?(dict.object_id)

        seen << dict.object_id
        value = yield(dict)
        return value if value

        parent = objects.deref!(dict[:Parent])
        walk_up(parent, objects, seen, &block)
      end
    end
  end
end
