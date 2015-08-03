require 'rmagick'

class DicomPack
  # extract projected images of a set of DICOM files
  def projection(dicom_directory, options = {})
    #use subdirectories axial, sagittal, coronal, slice names and avg/max sufixes

    strategy = DynamicRangeStrategy.min_max_strategy(options[:strategy] || :fixed, options)
    sequence = Sequence.new(dicom_directory, strategy: strategy)

    extract_dir = options[:output] || File.join(dicom_directory, 'images')
    FileUtils.mkdir_p FileUtils.mkdir_p extract_dir
    min, max = sequence.metadata.min, sequence.metadata.max

     if sequence.metadata.max <= 255
       bits = 8
     else
       bits = 16
    end

    xaxis = decode_vector(sequence.metadata.xaxis)
    yaxis = decode_vector(sequence.metadata.yaxis)
    zaxis = decode_vector(sequence.metadata.zaxis)
    if xaxis[0].abs != 1 || xaxis[1] != 0 || xaxis[2] != 0 ||
       yaxis[0] != 0 || yaxis[1] != 1 || yaxis[2] != 0 ||
       zaxis[0] != 0 || zaxis[1] != 0 || zaxis[2].abs != 1
      raise Error, "Unsupported orientation"
    end
    reverse_x = xaxis[0] < 0
    reverse_y = yaxis[1] < 0
    reverse_z = zaxis[2] < 0

    maxx = sequence.metadata.nx
    maxy = sequence.metadata.ny
    maxz = sequence.metadata.nz

    aggregation = aggregate_projection?(options[:axial]) ||
                  aggregate_projection?(options[:sagittal]) ||
                  aggregate_projection?(options[:coronal])

    # Load all the slices into a (big) 3D array
    # With type NArray::SINT instead of NArray::INT we would use up half the
    # memory, but each slice to be converted to image would have to be
    # convertd to INT...
    # volume = NArray.sint(maxx, maxy, maxz)
    volume = NArray.int(maxx, maxy, maxz)
    keeping_path do
      sequence.each do |dicom, z, file|
        puts file
        slice = strategy.pixels(dicom, min, max)
        volume[true, true, z] = slice
      end
    end
    # volume.add! -volume.min
    volume.add! -sequence.metadata.lim_min

    # TODO: if full_projection?(options[projection]))
    #       generate also 'avg' & 'max' for that projection

    if single_slice_projection?(options[:axial])
      axial_zs = [options[:axial].to_i]
    elsif full_projection?(options[:axial])
      axial_zs = (0...maxz)
    else
      axial_zs = []
    end
    axial_zs.each do |z|
      slice = volume[true, true, z]
      output_image = output_file_name(extract_dir, 'axial_', "#{z}")
      save_pixels slice, output_image, bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y
    end

    if single_slice_projection?(options[:sagittal])
      sagittal_xs = [options[:sagittal].to_i]
    elsif full_projection?(options[:sagittal])
      sagittal_xs = (0...maxx)
    else
      sagittal_xs = []
    end
    sagittal_xs.each do |x|
      slice = volume[x, true, true]
      output_image = output_file_name(extract_dir, 'sagittal_', "#{x}")
      save_pixels slice, output_image, bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z
    end

    if single_slice_projection?(options[:coronal])
      coronal_ys = [options[:coronal].to_i]
    elsif full_projection?(options[:coronal])
      coronal_ys = (0...maxx)
    else
      coronal_ys = []
    end
    coronal_ys.each do |y|
      slice = volume[true, y, true]
      output_image = output_file_name(extract_dir, 'coronal_', "#{y}")
      save_pixels slice, output_image, bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z
    end

    if aggregate_projection?(options[:axial])
      if options[:axial] == 'max'
        slice = volume.max(2) # aggregate dimension 2 (z)
      else # 'avg'
        slice = volume.mean(2)
      end
      output_image = output_file_name(extract_dir, 'axial_', "#{options[:axial]}")
      save_pixels slice, output_image, bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y
    end
    if aggregate_projection?(options[:coronal])
      if options[:coronal] == 'max'
        slice = volume.max(1) # aggregate dimension 1 (y)
      else # 'avg'
        slice = volume.mean(1)
      end
      output_image = output_file_name(extract_dir, 'coronal_', "#{options[:coronal]}")
      save_pixels slice, output_image, bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z
    end
    if aggregate_projection?(options[:sagittal])
      if options[:sagittal] == 'max'
        slice = volume.max(0) # aggregate dimension 0 (x)
      else # 'avg'
        slice = volume.mean(0)
      end
      output_image = output_file_name(extract_dir, 'sagittal_', "#{options[:sagittal]}")
      save_pixels slice, output_image, bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z
    end
  end

  private

  def axis_index(v, maxv, reverse)
    reverse ? maxv - v : v
  end

  def aggregate_projection?(axis_selection)
    ['avg', 'max'].include?(axis_selection)
  end

  def full_projection?(axis_selection)
    axis_selection == true
  end

  def single_slice_projection?(axis_selection)
    axis_selection.is_a?(String)  && /\A\d+\Z/ =~ axis_selection
  end

  def save_pixels(pixels, output_image, options = {})
    bits = options[:bit_depth] || 16
    reverse_x = options[:reverse_x]
    reverse_y = options[:reverse_y]
    columns, rows = pixels.shape
    rm_type = bits == 8 ? Magick::CharPixel : Magick::ShortPixel
    # blob = pixels.to_blob(bits)
    # image = Magick::Image.new(columns, rows).import_pixels(0, 0, columns, rows, rm_type, blob, 'I')
    image = Magick::Image.new(columns, rows).import_pixels(0, 0, columns, rows, 'I', pixels.flatten, rm_type)
    image.flip! if reverse_y
    image.flop! if reverse_x
    image.write(output_image)
  end

end
