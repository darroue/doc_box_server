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

    def call
      ODFReport::Report.new(@template_file_path) do |r|
        @data[:fields].each_pair do |key, value|
          r.add_field key.to_sym, value
        end

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
