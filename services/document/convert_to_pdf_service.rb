require 'odf-report'
require_relative '../../lib/odt_report/field'

module Document
  class ConvertToPdfService
    def initialize(params)
      @params = params
    end

    def call
      tempfile_path = @params[:file][:tempfile].path
      system "cd /tmp && soffice --headless -env:UserInstallation=file:///tmp/LibreOffice_Conversion_${USER} --convert-to pdf:draw_pdf_Export #{tempfile_path}"

      tempfile_path.sub(/.odt$/, '.pdf')
    end
  end
end
