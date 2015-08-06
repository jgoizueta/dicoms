class DicomPack
  # remap the dicom values of a set of images to maximize dynamic range
  # and avoid negative values
  # options:
  # * :level - apply window leveling
  # * :drop_base_level - remove lowest level (only if not doing window leveling)
  def remap(dicom_directory, options = {})
    output_dir = options[:output] ||
      File.join(File.dirname(dicom_directory), File.basename(dicom_directory)+'_remapped')
    FileUtils.mkdir_p output_dir

    # TODO: this way of passing strategy parameters to commands should be applied
    # elsehere (to avoid conflict between strategy parameters and other parameters, e.g. :output)
    #
    # Examples:
    #     strategy: :window
    #     strategy: [:window, center: c, level: l]
    #
    strategy = DynamicRangeStrategy.min_max_strategy(*Array(options[:strategy] || :fixed))
    sequence = Sequence.new(dicom_directory, strategy: strategy)

    dd_hack = options[:even_size]
    # Hack to solve problem with some DICOMS having different header size
    # (incovenient for some tests) due to differing 0008,2111 element

    dd = nil if dd_hack

    sequence.each do |dicom, i, file|
      if dd_hack
        dd ||= dicom.derivation_description
        dicom.derivation_description = dd
      end
      data = sequence.dicom_pixels(dicom)
      lim_min, lim_max = strategy.min_max_limits(dicom)
      if lim_min >= 0
        dicom.pixel_representation = 0
      else
        dicom.pixel_representation = 1
      end
      dicom.window_center = (lim_max + lim_min) / 2
      dicom.window_width = (lim_max - lim_min)
      dicom.pixels = data
      output_file = File.join(output_dir, File.basename(file))
      dicom.write output_file
    end
  end
end
