# frozen_string_literal: true

require 'tempfile'
require 'open3'

module Document
  module Pdf
    # Some PDFs (seen from a "Nitro" PDF producer CMap tag) carry Type0/CID
    # fonts with no embedded FontFile2/FontFile3 - the glyph outlines simply
    # aren't in the document. Screen viewers and Ghostscript quietly fall
    # back to *some* substitute; strict print RIPs abort with a "missing
    # resource for Type0 font substitution" dictionary error instead.
    #
    # Repairs each broken font in place: reads which Unicode character each
    # CID represents from the font's own /ToUnicode CMap, looks up the
    # matching glyph in a real embedded TrueType font (DejaVuSans, chosen
    # for Czech/Latin Extended-A coverage - see Fields::REPLACEMENT_FONT
    # sibling use in FillService), and writes a /CIDToGIDMap bridging the
    # document's existing CIDs to that font's glyph ids. Existing /Widths
    # are left untouched since they already describe the intended layout.
    class FontSanitizerService
      FONT_PATH = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'

      def self.call(pdf_path)
        new(pdf_path).call
      end

      def initialize(pdf_path)
        @pdf_path = pdf_path
      end

      def call
        qdf = to_qdf(@pdf_path)
        return @pdf_path unless qdf

        patched = patch_broken_fonts(qdf)
        return @pdf_path if patched.nil?

        rebuild(patched)
      end

      private

      def to_qdf(path)
        Tempfile.create(['fontsanitize', '.qdf']) do |out|
          _out, _err, status = Open3.capture3('qpdf', '--qdf', '--object-streams=disable', path, out.path)
          return nil unless status.success?

          return File.binread(out.path)
        end
      end

      def obj_body(qdf, num)
        qdf[/\n#{num} 0 obj\n(.*?)\nendobj/m, 1]
      end

      def broken_type0_fonts(qdf)
        qdf.scan(%r{(\d+) 0 obj\n<<\n((?:(?!\nendobj).)*?/Subtype /Type0(?:(?!\nendobj).)*?)\nendobj}m).filter_map do |_num, body|
          desc_ref = body[/\/DescendantFonts\s*(?:\[\s*)?(\d+) 0 R/, 1]
          tounicode_ref = body[/\/ToUnicode (\d+) 0 R/, 1]
          next unless desc_ref && tounicode_ref

          desc_body = obj_body(qdf, desc_ref)
          next unless desc_body

          fd_ref = desc_body[/\/FontDescriptor (\d+) 0 R/, 1]
          next unless fd_ref

          fd_body = obj_body(qdf, fd_ref)
          next if fd_body.nil? || fd_body.include?('/FontFile2') || fd_body.include?('/FontFile3')

          { desc_ref: desc_ref, desc_body: desc_body, fd_ref: fd_ref, tounicode_ref: tounicode_ref }
        end
      end

      def cid_to_unicode(qdf, tounicode_ref)
        stream = obj_body(qdf, tounicode_ref)[/stream\n(.*?)\nendstream/m, 1]
        map = {}
        stream.scan(/beginbfchar(.*?)endbfchar/m).each do |section|
          section.first.scan(/<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>/).each do |cid_hex, uni_hex|
            map[cid_hex.to_i(16)] = uni_hex[0, 4].to_i(16)
          end
        end
        map
      end

      def patch_broken_fonts(qdf)
        broken = broken_type0_fonts(qdf)
        return nil if broken.empty?

        next_num = qdf.scan(/\n(\d+) 0 obj\n/).map { |m| m[0].to_i }.max + 1
        cmap = font_cmap

        broken.each do |font|
          cid_to_uni = cid_to_unicode(qdf, font[:tounicode_ref])
          max_cid = cid_to_uni.keys.max || 0
          gid_map = Array.new(max_cid + 1, 0)
          cid_to_uni.each { |cid, uni| gid_map[cid] = cmap.gid_for(uni) }
          gid_map_bytes = gid_map.pack('n*')

          fontfile_num = next_num
          cidtogid_num = next_num + 1
          next_num += 2

          qdf = qdf.sub(/\n#{font[:fd_ref]} 0 obj\n<<\n/, "\\0  /FontFile2 #{fontfile_num} 0 R\n")

          if font[:desc_body].include?('/CIDToGIDMap')
            qdf = qdf.sub(/\/CIDToGIDMap\s+(?:\/\w+|\d+ 0 R)/, "/CIDToGIDMap #{cidtogid_num} 0 R")
          else
            qdf = qdf.sub(/\n#{font[:desc_ref]} 0 obj\n<<\n/, "\\0  /CIDToGIDMap #{cidtogid_num} 0 R\n")
          end

          qdf << "\n#{fontfile_num} 0 obj\n<<\n  /Length #{font_bytes.bytesize}\n  " \
                 "/Length1 #{font_bytes.bytesize}\n>>\nstream\n#{font_bytes}\nendstream\nendobj\n"
          qdf << "\n#{cidtogid_num} 0 obj\n<<\n  /Length #{gid_map_bytes.bytesize}\n>>\n" \
                 "stream\n#{gid_map_bytes}\nendstream\nendobj\n"
        end

        qdf
      end

      def font_bytes
        @font_bytes ||= File.binread(FONT_PATH)
      end

      def font_cmap
        @font_cmap ||= TrueTypeCmap.new(font_bytes)
      end

      def rebuild(qdf_content)
        Tempfile.create(['fontsanitized_in', '.qdf']) do |qdf_file|
          qdf_file.binmode
          qdf_file.write(qdf_content)
          qdf_file.flush

          out = Tempfile.new(['fontsanitized', '.pdf'])
          _out, _err, status = Open3.capture3('qpdf', qdf_file.path, out.path)
          return @pdf_path unless status.success? || status.exitstatus == 3

          out.path
        end
      end

      # Minimal TrueType 'cmap' format-4 (Windows/Unicode BMP) reader - just
      # enough to map a Unicode code point to its glyph id for repairing the
      # documents in FontSanitizerService.
      class TrueTypeCmap
        def initialize(data)
          @data = data
          offset = subtable_offset
          raise "unsupported cmap format #{format_at(offset)}" unless format_at(offset) == 4

          seg_count_x2 = uint16(offset + 6)
          @seg_count = seg_count_x2 / 2
          @end_code_off = offset + 14
          @start_code_off = @end_code_off + seg_count_x2 + 2
          @id_delta_off = @start_code_off + seg_count_x2
          @id_range_offset_off = @id_delta_off + seg_count_x2
        end

        def gid_for(codepoint)
          @seg_count.times do |i|
            end_code = uint16(@end_code_off + (i * 2))
            next if codepoint > end_code

            start_code = uint16(@start_code_off + (i * 2))
            return 0 if codepoint < start_code

            id_delta = int16(@id_delta_off + (i * 2))
            id_range_offset = uint16(@id_range_offset_off + (i * 2))
            return (codepoint + id_delta) & 0xFFFF if id_range_offset.zero?

            addr = @id_range_offset_off + (i * 2) + id_range_offset + (2 * (codepoint - start_code))
            glyph = uint16(addr)
            return 0 if glyph.zero?

            return (glyph + id_delta) & 0xFFFF
          end
          0
        end

        private

        def subtable_offset
          cmap_off = table_offset('cmap')
          n_subtables = uint16(cmap_off + 2)
          found = nil
          n_subtables.times do |i|
            rec = cmap_off + 4 + (i * 8)
            platform = uint16(rec)
            encoding = uint16(rec + 2)
            found = cmap_off + uint32(rec + 4) if platform == 3 && encoding == 1
          end
          raise 'no Windows Unicode BMP cmap subtable' unless found

          found
        end

        def table_offset(tag)
          num_tables = uint16(4)
          num_tables.times do |i|
            rec_off = 12 + (i * 16)
            return uint32(rec_off + 8) if @data.byteslice(rec_off, 4) == tag
          end
          raise "no #{tag} table"
        end

        def format_at(offset) = uint16(offset)
        def uint16(offset) = @data.byteslice(offset, 2).unpack1('n')
        def uint32(offset) = @data.byteslice(offset, 4).unpack1('N')

        def int16(offset)
          v = uint16(offset)
          v >= 0x8000 ? v - 0x10000 : v
        end
      end
    end
  end
end
