# frozen_string_literal: true

require 'open3'
require 'tempfile'

module Document
  module Pdf
    # Strips owner-password/AES-256 encryption dictionaries so downstream
    # tools that can't handle them (pdftk-java's iText engine chokes on
    # /Encrypt R6/AES-256) can still read/fill the AcroForm. No-op on
    # already-plain PDFs since qpdf --decrypt just passes them through.
    #
    # Returns [path, tempfile] rather than just a path - the Tempfile object
    # must stay referenced by the caller for as long as `path` is still
    # needed downstream, otherwise Ruby's GC can unlink it (via Tempfile's
    # finalizer) out from under a still-running qpdf/pdftk/soffice call.
    class DecryptService
      def self.call(path)
        decrypted = Tempfile.new(['decrypted', '.pdf'])
        decrypted.close

        _stdout, _stderr, status = Open3.capture3('qpdf', '--decrypt', path, decrypted.path)
        status.success? ? [decrypted.path, decrypted] : [path, nil]
      end
    end
  end
end
