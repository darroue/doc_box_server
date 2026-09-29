# DocBoxServer [![ci](https://github.com/darroue/doc_box_server/actions/workflows/docker.yml/badge.svg)](https://github.com/darroue/doc_box_server/actions/workflows/docker.yml)

This code (Docker image) serves a [Grape](https://github.com/ruby-grape/grape) JSON API for working with documents and QR codes. Documents are processed with LibreOffice, pdftk, poppler and qpdf.

## This is still in active development and code is not final. I'm gonna produce TAGs once I'm satisfied with state of main branch.

## Currently working

All endpoints live under `/api/v1`:

* `POST /document/odt/fill` - fill an ODT template with data (optional attached files); the result is returned as DOCX
* `POST /document/odt/convert_to_pdf` - convert an ODT to PDF
* `POST /document/pdf/fields` - extract AcroForm text fields (name, page, rect) from a PDF template
* `POST /document/pdf/fill` - fill AcroForm fields and/or stamp text and image overlays, optionally flatten
* `POST /document/pdf/preview` - rasterize a PDF page to PNG
* `POST /qrcode/payment` - generate a payment QR code (PNG)
* `POST /qrcode/text` - generate a QR code (PNG) from arbitrary text

## Running

```sh
docker compose up --build
```

The API listens on port 3000 inside the container (`EXPOSE 3000`); publish it with `-p 3000:3000` when using plain `docker run`. The container starts Puma and a headless LibreOffice daemon via Foreman.

Created by ``Petr Radouš``
