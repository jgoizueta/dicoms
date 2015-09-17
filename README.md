# DicomS: DICOM Series toolkit

DicomS is a Ruby toolkit for working with DICOM (CT/MRI) Series
(image sequences that compose a volume of density information).

It can be used through a command line interface
by using the `dicoms` executable script, or
from a Ruby program through the 'DicomS' class interface (API).

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'dicoms'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install dicoms

### Requirements

* [FFmpeg](https://www.ffmpeg.org/) (the command line tools).
* [ImageMagick](http://www.imagemagick.org/) (the library whichs is used by RMagick)

## Usage

The `dicoms` executable provides the following commands:

* Extract images: `dicoms extract DICOM-DIR ...`
* Generate projected images (on axial, sagittal and coronal planes):
  `dicoms project DICOM-DIR ...`
* Pack a DICOM series in compact form: `dicoms pack DICOM-DIR ...`
* Unpack a packed DICOM series: `dicoms unpack PACKED-FILE ...`

Use the command to get further help.

## License

Copyright (c) 2015 Javier Goizueta

This software is licensed under the
[GNU General Public License](./LICENSE.md) version 3.
