require 'fileutils'
require 'dicom'
require 'modalsettings'
require 'sys_cmd'
require 'narray'

require "dicompack/version"
require "dicompack/meta_codec"
require "dicompack/support"
require "dicompack/shared_files"
require "dicompack/progress"
require "dicompack/sequence"
require "dicompack/transfer"
require "dicompack/extract"
require "dicompack/pack"
require "dicompack/unpack"
require "dicompack/stats"
require "dicompack/projection"
require "dicompack/remap"

# TODO: require known SOP Class: 1.2.840.10008.5.1.4.1.1.2
# (in tag 0002,0002, Media Storage SOP Class UID)
# And Transfer Syntax 0002,0010 1.2.840.10008.1.2:
#   Implicit VR Little Endian: Default Transfer Syntax for DICOM
#

# TODO: option for pack to restore DICOM files;
# we need to adjust metadata elements (which refer to first slice)
# to each slice.
# elements that vary from slice to slice but whose variation probably doesn't matter:
#   0008,0033     Content Time
# elements that vary and should be removed:
#   0018,1151     X-Ray Tube Current
#   0018,1152     Exposure
# elements that should be adjusted:
#   0020,0013     Instance Number # increment by 1 for each slice
#   0020,0032     Image Position (Patient) # should be computed from additional metadata (dz)
#   0020,1041     Slice Location  # should be computed from additional metadata (dz)
# elements that may need adjusting depending on value restoration method:
#   0028,0100     Bits Allocated
#   0028,0101     Bits Stored
#   0028,0102     High Bit
#   0028,0103     Pixel Representation
#   0028,1050     Window Center
#   0028,1051     Window Width
#   0028,1052     Rescale Intercept
#   0028,1053     Rescale Slope
#   0028,1054     Rescale Type
# also, these element should be removed (because Pixel data is set by assigning an image)
#   7FE0,0000     Group Length
#   7FE0,0010     Pixel Data
# other varying elements that need further study: (vary in some studies)
#   0002,0000     File Meta Information Group Length # drop this and 0002,0001?
#   0002,0003     Media Storage SOP Instance UID
#   0008,0018     SOP Instance UID

class DicomPack

  def initialize(options = {})
    @settings = Settings[options]

    if @settings.image_processor
      DICOM.image_processor = @settings.image_processor.to_sym
    end

    @ffmpeg_options = { 'ffmpeg' => @settings.ffmpeg }
    # TODO: use quality level settings
    # TODO: temporary strategy option (:current_dir, :system_tmp, ...)
  end

  attr_reader :settings

  extend Support
  include Support

  private

  def meta_codec
    MetaCodec.new
  end

  # def optimize_dynamic_range(data, output_min, output_max, options = {})
  #   minimum, maximum = options[:range]
  #   r = (maximum - minimum).to_f
  #   data -= minimum
  #   data *= (output_max - output_min)/r
  #   data += output_min
  #   data[data < output_min] = output_min
  #   data[data > output_max] = output_max
  #   data
  # end

  def check_command(command)
    unless command.success?
      puts "Error executing:"
      puts "  #{command}"
      puts command.error_output
      exit 1
    end
  end
end
