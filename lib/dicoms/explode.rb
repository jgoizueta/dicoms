require 'rmagick'

class DicomS
  # Extract all projected views (all slices in the three axis,
  # plus aap and mip projectios)
  def explode(dicom_directory, options = {})
    options = CommandOptions[options]

    progress = Progress.new('projecting', options)
    progress.begin_subprocess 'reading_metadata', 1

    # Create sequence without a transfer strategy
    # (identity strategy with rescaling would also do)
    # so that we're working with Hounsfield units
    sequence = Sequence.new(
      dicom_directory,
      reorder: options[:reorder]
    )

    slice_transfer = define_transfer(
      options,
      :window,
      output: :unsigned
    )
    mip_transfer = define_transfer(
      { transfer: options[:mip_transfer] },
      :fixed,
      min: -1000, max: 2000,
      output: :unsigned
    )
    aap_transfer = Transfer.strategy :fixed, min: 0.0, max: 1.0, float: true, output: :unsigned

    extract_dir = options.path_option(
      :output, File.join(File.expand_path(dicom_directory), 'images')
    )
    FileUtils.mkdir_p extract_dir

    if sequence.metadata.lim_max <= 255
       bits = 8
     else
       bits = 16
    end

    scaling = projection_scaling(sequence.metadata, options)
    sequence.metadata.merge! scaling
    scaling = Settings[scaling]

    reverse_x = sequence.metadata.reverse_x.to_i == 1
    reverse_y = sequence.metadata.reverse_y.to_i == 1
    reverse_z = sequence.metadata.reverse_z.to_i == 1

    maxx = sequence.metadata.nx
    maxy = sequence.metadata.ny
    maxz = sequence.metadata.nz

    # minimum and maximum slices with non-(almost)-blank contents
    minx_contents = maxx
    maxx_contents = 0
    miny_contents = maxy
    maxy_contents = 0
    minz_contents = maxz
    maxz_contents = 0

    progress.begin_subprocess 'generating_volume', 50, maxz

    # Load all the slices into a floating point 3D array
    volume = NArray.sfloat(maxx, maxy, maxz)
    keeping_path do
      sequence.each do |dicom, z, file|
        slice = sequence.dicom_pixels(dicom)
        volume[true, true, z] = slice
        progress.update_subprocess z
      end
    end

    maxv = volume.max

    # Generate slices

    axial_zs = (0...maxz)
    sagittal_xs = (0...maxx)
    coronal_ys = (0...maxy)

    # Will determine first and last slice with noticeable contents in each axis
    # Slices outside the range won't be generated to save space
    # This information will also be used for the app projection
    minx_contents = maxx
    maxx_contents = 0
    miny_contents = maxy
    maxy_contents = 0
    minz_contents = maxz
    maxz_contents = 0

    n = axial_zs.size + sagittal_xs.size + coronal_ys.size

    progress.begin_subprocess 'generating_slices', -70, n if n > 0
    axial_zs.each_with_index do |z, i|
      slice = volume[true, true, z]
      minz_contents, maxz_contents = update_min_max_contents(
        z, slice.max, maxv, minz_contents, maxz_contents
      )
      next unless (minz_contents..maxz_contents).include?(z)
      output_image = output_file_name(extract_dir, 'axial_', z.to_s)
      save_transferred_pixels sequence, slice_transfer, slice, output_image,
        bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y,
        cols: scaling.scaled_nx, rows: scaling.scaled_ny,
        normalize: NORMALIZE_PROJECTION_IMAGES
      progress.update_subprocess i
    end
    sagittal_xs.each_with_index do |x, i|
      slice = volume[x, true, true]
      minx_contents, maxx_contents = update_min_max_contents(
        x, slice.max, maxv, minx_contents, maxx_contents
      )
      next unless (minx_contents..maxx_contents).include?(x)
      output_image = output_file_name(extract_dir, 'sagittal_', x.to_s)
      save_transferred_pixels sequence, slice_transfer, slice, output_image,
        bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z,
        cols: scaling.scaled_ny, rows: scaling.scaled_nz,
        normalize: NORMALIZE_PROJECTION_IMAGES
      progress.update_subprocess axial_zs.size + i
    end
    coronal_ys.each_with_index do |y, i|
      slice = volume[true, y, true]
      miny_contents, maxy_contents = update_min_max_contents(
        y, slice.max, maxv, miny_contents, maxy_contents
      )
      next unless (miny_contents..maxy_contents).include?(y)
      output_image = output_file_name(extract_dir, 'coronal_', y.to_s)
      save_transferred_pixels sequence, slice_transfer, slice, output_image,
        bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z,
        cols: scaling.scaled_nx, rows: scaling.scaled_nz,
        normalize: NORMALIZE_PROJECTION_IMAGES
      progress.update_subprocess axial_zs.size + sagittal_xs.size + i
    end

    progress.begin_subprocess 'generating_projections', 100, 6

    # Generate MIP projections
    slice = maximum_intensity_projection(volume, Z_AXIS)
    output_image = output_file_name(extract_dir, 'axial_', 'mip')
    save_transferred_pixels sequence, mip_transfer, slice, output_image,
      bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y,
      cols: scaling.scaled_nx, rows: scaling.scaled_ny,
      normalize: NORMALIZE_PROJECTION_IMAGES
    progress.update_subprocess 1

    slice = maximum_intensity_projection(volume, Y_AXIS)
    output_image = output_file_name(extract_dir, 'coronal_', 'mip')
    save_transferred_pixels sequence, mip_transfer, slice, output_image,
      bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z,
      cols: scaling.scaled_nx, rows: scaling.scaled_nz,
      normalize: NORMALIZE_PROJECTION_IMAGES
    progress.update_subprocess 2

    slice = maximum_intensity_projection(volume, X_AXIS)
    output_image = output_file_name(extract_dir, 'sagittal_', 'mip')
    save_transferred_pixels sequence, mip_transfer, slice, output_image,
      bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z,
      cols: scaling.scaled_ny, rows: scaling.scaled_nz,
      normalize: NORMALIZE_PROJECTION_IMAGES
    progress.update_subprocess 3

    # Generate AAP Projections
    vmin = volume.min
    volume.add! -vmin
    volume.mul! 1.0/volume.max

    # apply gamma of 4 before app
    volume.mul! volume
    volume.mul! volume

    # Image corrections
    gamma_factor = 1.2
    contrast_factor = 3.5

    # Number of slices with non-blank contents
    numx = maxx_contents - minx_contents + 1
    numy = maxy_contents - miny_contents + 1
    numz = maxz_contents - minz_contents + 1

    slice = accumulated_attenuation_projection(
      volume, Z_AXIS, 1.0, numz, 0.02
    ).to_type(volume.typecode)
    slice = gamma(slice, gamma_factor) if gamma_factor
    contrast! slice, contrast_factor
    output_image = output_file_name(extract_dir, 'axial_', 'aap')
    save_transferred_pixels sequence, aap_transfer, slice, output_image,
      bit_depth: bits, reverse_x: reverse_x, reverse_y: reverse_y,
      cols: scaling.scaled_nx, rows: scaling.scaled_ny,
      normalize: NORMALIZE_PROJECTION_IMAGES
    progress.update_subprocess 4

    slice = accumulated_attenuation_projection(
      volume, Y_AXIS, 1.0, numy, 0.02
    ).to_type(volume.typecode)
    slice = gamma(slice, gamma_factor) if gamma_factor
    contrast! slice, contrast_factor
    output_image = output_file_name(extract_dir, 'coronal_', 'aap')
    save_transferred_pixels sequence, aap_transfer, slice, output_image,
      bit_depth: bits, reverse_x: reverse_x, reverse_y: !reverse_z,
      cols: scaling.scaled_nx, rows: scaling.scaled_nz,
      normalize: NORMALIZE_PROJECTION_IMAGES
    progress.update_subprocess 5

    slice = accumulated_attenuation_projection(
      volume, X_AXIS, 1.0, numx, 0.02
    ).to_type(volume.typecode)
    slice = gamma(slice, gamma_factor) if gamma_factor
    contrast! slice, contrast_factor
    output_image = output_file_name(extract_dir, 'sagittal_', 'aap')
    save_transferred_pixels sequence, aap_transfer, slice, output_image,
      bit_depth: bits, reverse_x: !reverse_y, reverse_y: !reverse_z,
      cols: scaling.scaled_ny, rows: scaling.scaled_nz,
      normalize: NORMALIZE_PROJECTION_IMAGES
    progress.update_subprocess 5

    volume = nil
    sequence.metadata.merge!(
      axial_first: minz_contents, axial_last: maxz_contents,
      coronal_first: miny_contents, coronal_last: maxy_contents,
      sagittal_first: minz_contents, sagittal_last: maxz_contents
    )
    options.save_settings 'projection', sequence.metadata
    progress.finish
  end

  private

  def contrast!(data, factor)
    # We use this piecewise sigmoid function:
    #
    # * f(x)       for x <= 1/2
    # * 1 - f(1-x) for x > 1/2
    #
    # With f(x) = pow(2, factor-1)*pow(x, factor)
    # The pow() function will be computed as:
    # pow(x, y) = exp(y*log(x))
    #
    # TODO: consider this alternative:
    # f(x) = (factor*x - x)/(2*factor*x - factor - 1
    #)
    factor = factor.round
    k = 2**(factor-1)
    lo = data <= 0.5
    hi = data >  0.5
    data[lo] = NMath.exp(factor*NMath.log(data[lo]))*k
    data[hi] = (-NMath.exp(NMath.log((-data[hi]) + 1)*factor))*k+1
    data
  end

  def gamma(data, factor)
    NMath.exp(factor*NMath.log(data))
  end

  def save_transferred_pixels(sequence, transfer, pixels, output_image, options)
    dicom = sequence.first
    min, max = transfer.min_max(sequence)
    pixels = transfer.transfer_rescaled_pixels(dicom, pixels, min, max)
    save_pixels pixels, output_image, options
  end
end
