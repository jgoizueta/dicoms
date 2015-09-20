require 'fileutils'
require 'dicom'
require 'modalsettings'
require 'sys_cmd'
require 'narray'

require "dicoms/version"
require "dicoms/meta_codec"
require "dicoms/support"
require "dicoms/shared_files"
require "dicoms/shared_settings"
require "dicoms/progress"
require "dicoms/command_options"
require "dicoms/sequence"
require "dicoms/transfer"
require "dicoms/extract"
require "dicoms/pack"
require "dicoms/unpack"
require "dicoms/stats"
require "dicoms/projection"
require "dicoms/remap"
require "dicoms/explode"

class DicomS

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
