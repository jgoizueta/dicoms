class DicomPack
  # remap the dicom values of a set of images to maximize dynamic range
  # and avoid negative values
  # options:
  # * :level - apply window leveling
  # * :drop_base_level - remove lowest level (only if not doing window leveling)
  def remap(dicom_directory, options = {})
    dicom_files = find_dicom_files(dicom_directory)
    if dicom_files.empty?
      raise "ERROR: no se han encontrado archivos DICOM en: \n #{dicom_directory}"
    end

    output_dir = options[:output] || (dicom_directory+'_remapped')
    FileUtils.mkdir_p output_dir


    if options[:strategy] != :unsigned
      strategy = DynamicRangeStrategy.min_max_strategy(options[:strategy] || :fixed, options)
      min, max = strategy.min_max(dicom_files)
    end

    dd_hack = true
    # Hack to solve problem with some DICOMS having different header size
    # (incovenient for some tests) due to differing 0008,2111 element

    if dd_hack
      first = true
      dd = nil
    end

    dicom_files.each do |file|
      d = DICOM::DObject.read(file)
      if dd_hack
        dd = d.derivation_description if first
        d.derivation_description = dd
      end
      lim_min, lim_max = DynamicRangeStrategy.min_max_limits(d)
      if options[:strategy] == :unsigned
        if lim_min < 0
          offset = -lim_min
        else
          offset = 0
        end
      end
      if offset
        if offset != 0
          d.window_center = d.window_center.value.to_i + offset
          d.pixel_representation = 0
          data = d.narray
          data += offset
          d.pixels = data
        end
      else
        if (min < lim_min || max > lim_max)
          if min >= 0
            d.pixel_representation = 0
          else
            d.pixel_representation = 1
          end
        end
        lim_min, lim_max = DynamicRangeStrategy.min_max_limits(d)
        d.window_center = (lim_max + lim_min) / 2
        d.window_width = (lim_max - lim_min)
        d.pixels = strategy.processed_data(d, min, max)
      end
      output_file = File.join(output_dir, File.basename(file))
      d.write output_file
    end
  end
end
