class DicomPack
  # extract projected images of a set of DICOM files
  def projection(dicom_directory, options = {})
    #use subdirectories axial, sagittal, coronal, slice names and avg/max sufixes

    strategy = DynamicRangeStrategy.min_max_strategy(options[:strategy] || :fixed, options)
    sequence = Sequence.new(dicom_directory, strategy: strategy)

    extract_dir = options[:output] || File.join(dicom_directory, 'images')
    FileUtils.mkdir_p FileUtils.mkdir_p pack_dir
    prefix = nil
    min, max = sequence.metatada.min, sequence.metatada.max

    xaxis = decode_vector(sequence.metadata.xaxis
    yaxis = decode_vector(sequence.metadata.yaxis
    zaxis = decode_vector(sequence.metadata.zaxis
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

    # Initialize axial/sagittal/coronal views needed:
    if aggregate_projection?(options[:axial])
      view_maxx = maxx
      view_maxy = maxy
      axial = Magick::Image.new(view_maxx, view_maxy) { self.background_color = 'black' }
      # TODO: use a Matrix of Floats for options[:axial] == 'avg'; better yet: use narray
    end
    if options[:coronal]
      view_maxx = maxx
      view_maxy = maxz
      coronal = Magick::Image.new(view_maxx, view_maxy) { self.background_color = 'black' }
      # TODO: use a Matrix of Floats for options[:coronal] == 'avg'; better yet: use narray
    end
    if options[:sagittal]
      view_maxx = maxy
      view_maxy = maxz
      sagittal = Magick::Image.new(view_maxx, view_maxy) { self.background_color = 'black' }
      # TODO: use a Matrix of Floats for options[:sagittal] == 'avg'; better yet: use narray
    end

    keeping_path do
      sequence.each do |dicom, z, file|
        slice = strategy.image(dicom, min, max)
        unless prefix
          prefix, name_pattern, start_number = dicom_name_pattern(file, extract_dir)
        end

        if aggregation
          (0...maxx).each do |x|
            (0...maxy).each do |y|
              d = slice.pixel(x, y)
              if aggregate_projection?(options[:axial])
                update_projection(axial, axis_index(x, maxx, reverse_x), axis_index(y, maxy, reverse_y), d, options[:axial])
              end
              if aggregate_projection?(options[:sagittal])
                update_projection(saggital, axis_index(y, maxy, !reverse_y), axis_index(z, maxz, !reverse_z), d, options[:sagittal])
              end
              if aggregate_projection?(options[:coronal])
                update_projection(coronal axis_index(x, maxx, reverse_x), axis_index(z, maxz, !reverse_z), d, options[:coronal])
              end
            end
          end
          # TODO: if 'avg' aggregation is used, now pixel values must be divided by:
          # * axial: maxz
          # * sagittal: maxx
          # * coronal: maxy
        end
        if single_slice_projection?(options[:axial])
          if options[:axial].to_i == axis_index(z, maxz, reverse_z)
            save_axial_slice = true
          end
        elsif full_projection?(options[:axial])
          save_axial_slice = true
        end
        if save_axial_slice
          output_image = output_file_name(extract_dir, prefix, file)
          image = slice
          if reverse_x
            image = image.flop
          end
          if reverse_y
            image = image.flip
          end
          save_jpg image, output_image, strategy, min, max
        end

        # currently full projection now supported for sagittal, coronal
        # TODO: for that case repeat this for each saggital/coronal slice
        if single_slice_projection?(options[:coronal])
          i = axis_index(options[:coronal].to_i, maxy, reverse_y)
          j = axis_index(z, maxz, !reverse_z)
          # row i of slice becomes row j of coronal view
          (0...maxx).each do |k|
            set_image_pixel coronal, axis_index(k, maxx, reverse_x), j, get_image_pixel(slice, k, i)
          end
        end

        if single_slice_projection?(options[:sagittal])
          i = axis_index(options[:sagittal].to_i, maxx, reverse_x)
          j = axis_index(z, maxz, !reverse_z)
          # column i of slice becomes row j of sagittal view in reverse order
          (0...maxy).each do |k|
            set_image_pixel sagittal, axis_index(k, maxy, !reverse_y), j, get_image_pixel(slice, i, k)
          end
        end
      end
      # TODO: save axial (if aggregate), coronal, sagittal
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

  def set_image_pixel(i, j, value)
    image.pixel_color i, j, Magick::Pixel.new(value, value, value, 0)
  end

  def get_image_pizel(i, j)
    image.pixel_color(i, j).intensity
  end

  def update_projection(image, col, row, value, aggregation)
    case aggregation
    when 'max'
      prev_value = get_image_pixel(image, col, row)
      if prev_value && prev_value < value
        set_image_pixel image, col, row, value
      end
    when 'avg'
      # TODO: this cannot be handled like this: need to use an array to avoid overflow
      # (use Floats to avoid large integers too)
      prev_value = get_image_pixel(image, col, row) || 0
      set_image_pixel image, col, row, prev_value + value
    end
  end

end
