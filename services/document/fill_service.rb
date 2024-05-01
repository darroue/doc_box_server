require 'odf-report'

require_relative '../../lib/odt_report/field'

module Document
  class FillService
    def initialize(params, tempfile)
      @params = params
      @tempfile_path = tempfile.path
      @template_file_path = params[:template][:tempfile]
      @files = params[:files]
      @data = params[:data]
    end

    def call # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
      ODFReport::Report.new(@template_file_path) do |r|
        tables = @data[:tables]
        tables = tables.is_a?(Hash) ? tables : {}
        tables.each_pair do |table_name, rows|

          columns = if rows.is_a?(Array)
                      if rows.first.is_a?(Hash)
                        if rows.first.keys.is_a?(Array)
                          rows.first.keys
                        end
                      end
                    end || []
          rows = [] unless rows.is_a?(Array)

          r.add_table(table_name, rows, header: true) do |t|
           return unless columns.is_a?(Array)

           columns.each do |column|
              t.add_field(column.to_sym) do |row|
                row[column]
              end
            end
          end
        end

        @data[:fields].each_pair do |key, value|
          r.add_field key.to_sym, value
        end

        return unless @files.is_a?(Array)

        @files.each do |file|
          placeholder = @data[:images][file[:filename]]
          next unless placeholder

          r.add_image placeholder.to_sym, file[:tempfile]
        end
      end.generate(@tempfile_path)

      @tempfile_path
    end
  end
end
