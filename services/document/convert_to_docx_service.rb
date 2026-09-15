require 'open3'
require 'tmpdir'
require 'fileutils'
require 'tempfile'

module Document
  # Converts a filled ODT (from FillService) to DOCX via LibreOffice. This
  # sidesteps ODT-specific zip packaging quirks (see rubyzip/odf-report
  # mimetype entry issue) that old LibreOffice versions can be strict about -
  # the DOCX comes straight out of LibreOffice's own writer, so it's always
  # standard-compliant.
  class ConvertToDocxService
    def initialize(odt_path)
      @odt_path = odt_path
    end

    def call
      Dir.mktmpdir do |dir|
        input_path = File.join(dir, 'input.odt')
        FileUtils.cp(@odt_path, input_path)

        profile_dir = File.join(dir, 'libreoffice-profile')
        _stdout, stderr, status = Open3.capture3(
          'soffice', '--headless', "-env:UserInstallation=file://#{profile_dir}",
          '--convert-to', 'docx', '--outdir', dir, input_path
        )
        raise "soffice conversion failed: #{stderr}" unless status.success?

        output = Tempfile.new(%w[converted .docx])
        FileUtils.cp(File.join(dir, 'input.docx'), output.path)
        output.path
      end
    end
  end
end
