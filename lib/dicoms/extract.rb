class DicomS
  # extract the images of a set of DICOM files
  def extract(dicom_directory, options = {})
    options = CommandOptions[options]

    progress = Progress.new('extracting', options)
    progress.begin_subprocess 'reading_metadata', 2

    strategy = define_transfer(options, :window)
    sequence = Sequence.new(
      dicom_directory,
      transfer: strategy,
      reorder: options[:reorder]
    )

    progress.begin_subprocess 'extracting_images', 100, sequence.size

    extract_dir = options.path_option(
      :output, File.join(File.expand_path(dicom_directory), 'images')
    )
    FileUtils.mkdir_p FileUtils.mkdir_p extract_dir
    prefix = nil
    min, max = sequence.metadata.min, sequence.metadata.max
    sequence.each do |d, i, file|
      unless prefix
        prefix, name_pattern, start_number = dicom_name_pattern(file, extract_dir)
      end
      if options.raw
        output_file = output_file_name(extract_dir, prefix, file, '.raw')
        endianness = dicom_endianness(d, options)
        sequence.metadata.endianness = endianness.to_s
        bits = dicom_bit_depth(d)
        signed = dicom_signed?(d)
        fmt = pack_format(bits, signed, endianness)
        File.open(output_file, 'wb') do |out|
          out.write sequence.dicom_pixels(d).flatten.to_a.pack("#{fmt}*")
        end
      else
        output_image = output_file_name(extract_dir, prefix, file)
        sequence.save_jpg d, output_image
      end
      progress.update_subprocess i
    end

    metadata = cast_metadata(sequence.metadata)
    metadata_yaml = File.join(extract_dir, 'metadata.yml')
    File.open(metadata_yaml, 'w') do |yaml|
      yaml.write metadata.to_yaml
    end

    progress.finish
  end

  def dicom_endianness(dicom, options = {})
    if options[:big_endian]
      :big
    elsif options[:little_endian]
      :little
    elsif dicom.stream.str_endian
      :big
    else
      :little
    end
  end

  def pack_format(bits, signed, endianness)
    if bits > 16
      if signed
        endianness == :little ? 'l<' : 'l>'
      else
        endianness == :little ? 'L<' : 'L>'
      end
    elsif bits > 8
      if signed
        endianness == :little ? 's<' : 's>'
      else
        endianness == :little ? 'S<' : 'S>'
      end
    else
      if signed
        "c"
      else
        "C"
      end
    end
  end
end
