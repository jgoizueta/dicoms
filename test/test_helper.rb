$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'dicoms'

require 'minitest/autorun'

DICOM.logger.level = Logger::ERROR
