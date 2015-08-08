class DicomPack
  # remap the dicom values of a set of images to maximize dynamic range
  # and avoid negative values
  def remap(dicom_directory, options = {})
    options = CommandOptions.new(options)

    progress = Progress.new('remapping', options)
    progress.begin_subprocess 'reading_metadata', 2

    output_dir = options.path_option(:output,
      File.join(File.dirname(dicom_directory), File.basename(dicom_directory)+'_remapped')
    )
    FileUtils.mkdir_p output_dir

    strategy = define_transfer(options, :identity)
    sequence = Sequence.new(dicom_directory, transfer: strategy)

    dd_hack = options[:even_size]
    # Hack to solve problem with some DICOMS having different header size
    # (incovenient for some tests) due to differing 0008,2111 element

    dd = nil if dd_hack

    progress.begin_subprocess 'remapping_slices', 100, sequence.size
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
      progress.update_subprocess i
    end
    progress.finish
  end
end
