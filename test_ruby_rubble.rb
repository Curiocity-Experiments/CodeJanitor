require 'simplecov'
SimpleCov.start

require 'minitest/autorun'
require 'minitest/stub_const'
require 'fileutils'

require_relative 'RubyRubble'

class TestRubyRubble < Minitest::Test
	def setup
	  @test_dir = File.expand_path('../test_files', __FILE__)
	  FileUtils.mkdir_p(File.join(@test_dir, 'config'))
	  File.write(File.join(@test_dir, 'config', 'application.rb'), "")
	  @rubyrubble = RubyRubble.new(@test_dir)
	end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  def test_should_ignore_with_nonexistent_directories
    File.write(File.join(@test_dir, '.gitignore'), "*.log\ntemp/")
    ignore_patterns = @rubyrubble.send(:parse_gitignore, @test_dir)

    # Add a non-existent directory to the config
    @rubyrubble.stub :config, @rubyrubble.config.merge('ignore_dirs' => ['nonexistent_dir']) do
      ['app.log', File.join('temp', 'file.txt'), 'app.rb'].each do |file|
        file_path = File.join(@test_dir, file)
        result = @rubyrubble.send(:should_ignore?, file_path, ignore_patterns)
        if file == 'app.rb'
          refute result, "#{file} should not be ignored"
        else
          assert result, "#{file} should be ignored"
        end
      end
    end
  end

  def test_get_required_files
    content = "require 'foo'\nrequire_relative 'bar'\nclass Baz\nend"
    file_path = File.join(@test_dir, 'test.rb')
    File.write(file_path, content)

    @rubyrubble.stub :is_rails, false do
      required_files = @rubyrubble.send(:get_required_files, file_path)
      assert_equal ['foo', 'bar'], required_files
    end

    @rubyrubble.stub :is_rails, true do
      required_files = @rubyrubble.send(:get_required_files, file_path)
      assert_equal ['foo', 'bar', 'baz'], required_files
    end
  end

  def test_find_unused_files
    # Create some test files
    File.write(File.join(@test_dir, 'main.rb'), "require_relative 'foo'\nrequire_relative 'bar'")
    File.write(File.join(@test_dir, 'foo.rb'), "")
    File.write(File.join(@test_dir, 'bar.rb'), "")
    File.write(File.join(@test_dir, 'unused.rb'), "")

    @rubyrubble.stub :is_rails, false do
      @rubyrubble.stub :config, @rubyrubble.config.merge('main_files' => ['main.rb']) do
        unused, problematic, large, all_files = @rubyrubble.send(:find_unused_files)

        assert_includes unused, File.join(@test_dir, 'unused.rb')
        refute_includes unused, File.join(@test_dir, 'foo.rb')
        refute_includes unused, File.join(@test_dir, 'bar.rb')
        refute_includes unused, File.join(@test_dir, 'main.rb')
      end
    end
  end

  def test_delete_files
    file_path = File.join(@test_dir, 'test.rb')
    File.write(file_path, "")

    @rubyrubble.send(:delete_files, [file_path])

    refute File.exist?(file_path)
  end

  def test_move_to_archive
    file_path = File.join(@test_dir, 'test.rb')
    File.write(file_path, "")
    archive_folder = File.join(@test_dir, 'archive')

    @rubyrubble.send(:move_to_archive, [file_path], archive_folder)

    refute File.exist?(file_path)
    assert File.exist?(File.join(archive_folder, 'test.rb'))
  end

  def test_log_error
    exception = RuntimeError.new("Test error")
    assert_output(/Error: Failed to perform operation\nException: Test error/) do
      @rubyrubble.send(:log_error, "Failed to perform operation", exception)
    end
  end

  def test_detect_rails
    FileUtils.mkdir_p(File.join(@test_dir, 'config'))
    File.write(File.join(@test_dir, 'config', 'application.rb'), "")

    assert @rubyrubble.send(:detect_rails)

    FileUtils.rm_rf(File.join(@test_dir, 'config'))

    refute @rubyrubble.send(:detect_rails)
  end

  def test_load_config
    File.write(File.join(@test_dir, 'config.yml'), { 'ignore_dirs' => ['custom_dir'] }.to_yaml)

    config = @rubyrubble.send(:load_config)
    assert_equal ['custom_dir'], config['ignore_dirs']

    FileUtils.rm_rf(File.join(@test_dir, 'config.yml'))

    config = @rubyrubble.send(:load_config)
    assert_equal RubyRubble::DEFAULT_CONFIG['ignore_dirs'].to_a, config['ignore_dirs']
  end

  def test_parse_options
    ARGV.replace(['-d'])
    options = @rubyrubble.send(:parse_options)
    assert options[:dry_run]

    ARGV.replace([])
    options = @rubyrubble.send(:parse_options)
    refute options[:dry_run]
  end

  def test_format_size
    assert_equal '1.00 KB', @rubyrubble.send(:format_size, 1024)
    assert_equal '1.00 MB', @rubyrubble.send(:format_size, 1024 * 1024)
    assert_equal '1.00 GB', @rubyrubble.send(:format_size, 1024 * 1024 * 1024)
  end

  def test_format_date
    today = Date.today
    assert_equal today.strftime("%I:%M %p"), @rubyrubble.send(:format_date, today)

    yesterday = Date.today - 1
    assert_equal yesterday.strftime("%A, %b %d, %Y"), @rubyrubble.send(:format_date, yesterday)
  end
end

def test_initialize_and_load_config
  File.write(File.join(@test_dir, 'config.yml'), { 'ignore_dirs' => ['custom_dir'] }.to_yaml)
  rubyrubble = RubyRubble.new(@test_dir)

  assert_equal @test_dir, rubyrubble.app_directory
  assert_equal ['custom_dir'], rubyrubble.config['ignore_dirs']
end

def test_delete_files
  file_path = File.join(@test_dir, 'test.rb')
  File.write(file_path, "")

  @rubyrubble.send(:delete_files, [file_path])

  refute File.exist?(file_path)
end

def test_move_to_archive
  file_path = File.join(@test_dir, 'test.rb')
  File.write(file_path, "")
  archive_folder = File.join(@test_dir, 'archive')

  @rubyrubble.send(:move_to_archive, [file_path], archive_folder)

  refute File.exist?(file_path)
  assert File.exist?(File.join(archive_folder, 'test.rb'))
end

def test_get_file_info
  file_path = File.join(@test_dir, 'test.rb')
  File.write(file_path, "test content")

  file_info = @rubyrubble.send(:get_file_info, file_path)

  assert_equal 12, file_info[:size]
  assert file_info[:created].is_a?(Time)
  assert file_info[:modified].is_a?(Time)
end

def test_find_unused_files
  # Create some test files
  File.write(File.join(@test_dir, 'main.rb'), "require_relative 'foo'\nrequire_relative 'bar'")
  File.write(File.join(@test_dir, 'foo.rb'), "")
  File.write(File.join(@test_dir, 'bar.rb'), "")
  File.write(File.join(@test_dir, 'unused.rb'), "")

  @rubyrubble.stub :is_rails, false do
    @rubyrubble.stub :config, @rubyrubble.config.merge('main_files' => ['main.rb']) do
      unused, problematic, large, all_files = @rubyrubble.send(:find_unused_files)

      assert_includes unused, File.join(@test_dir, 'unused.rb')
      refute_includes unused, File.join(@test_dir, 'foo.rb')
      refute_includes unused, File.join(@test_dir, 'bar.rb')
      refute_includes unused, File.join(@test_dir, 'main.rb')
    end
  end
end
