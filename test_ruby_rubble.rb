require 'simplecov'
SimpleCov.start

require 'minitest/autorun'
require 'minitest/stub_const'
require 'fileutils'

require_relative 'RubyRubble'

class TestRubyRubble < Minitest::Test
  def setup
    @test_dir = File.expand_path('../test_files', __FILE__)
    FileUtils.mkdir_p(@test_dir)
    @rubyrubble = RubyRubble.new(@test_dir)
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  def test_should_ignore
    File.write(File.join(@test_dir, '.gitignore'), "*.log\ntemp/")
    ignore_patterns = @rubyrubble.send(:parse_gitignore, @test_dir)

    puts "Debug: @test_dir = #{@test_dir}"
    puts "Debug: ignore_patterns = #{ignore_patterns.inspect}"

    ['app.log', File.join('temp', 'file.txt'), 'app.rb'].each do |file|
      file_path = File.join(@test_dir, file)
      result = @rubyrubble.send(:should_ignore?, file_path, ignore_patterns)
      puts "Debug: file_path = #{file_path}, result = #{result}"
      if file == 'app.rb'
        refute result, "#{file} should not be ignored"
      else
        assert result, "#{file} should be ignored"
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

  def test_interactive_select
    options = ['file1.rb', 'file2.rb', 'file3.rb']

    # Simulate user input: select all files and choose to delete
    simulate_user_input(['a', 'd']) do
      result = @rubyrubble.send(:interactive_select, options, 0)
      assert_equal [options, 'delete'], result
    end

    # Simulate user input: quit without selecting
    simulate_user_input(['q']) do
      result = @rubyrubble.send(:interactive_select, options, 0)
      assert_nil result
    end
  end

  def simulate_user_input(inputs)
    input_queue = inputs.dup
    @rubyrubble.stub :get_char, -> { input_queue.shift || 'q' } do
      yield
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
end
