require 'test_helper'

class DicomPackTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::DicomPack::VERSION
  end
end
