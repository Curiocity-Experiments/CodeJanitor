#!/usr/bin/env ruby

require 'set'
require 'fileutils'
require 'date'
require 'yaml'
require 'optparse'
require 'digest'
require 'json'
require 'ruby-progressbar'
require 'pathname'

begin
  require 'parallel'
rescue LoadError
  puts "The 'parallel' gem is not installed. Running in single-threaded mode."
  module Parallel
    def self.each(enumerable, &block)
      enumerable.each(&block)
    end
  end
end

class RubyRubble
  REQUIRED_RUBY_VERSION = '2.5.0'
  CONFIG_FILE = 'config.yml'
  DEFAULT_CONFIG = {
    'ignore_dirs' => Set.new(%w[vendor .git .bundle tmp log public]),
    'extensions' => %w[.rb .rake .erb .haml .slim],
    'size_threshold' => 1024 * 1024,
    'exclude_self' => true,
    'archive_folder' => 'Matz_Museum',
    'main_files' => []
  }

  attr_reader :config, :options, :app_directory, :archive_path, :is_rails

  def initialize(app_directory)
    @app_directory = app_directory
    @config = load_config
    @options = parse_options
    @archive_path = File.join(app_directory, config['archive_folder'])
    @is_rails = detect_rails
  end

  def run
    check_ruby_version
    puts "Running RubyRubble with Ruby #{RUBY_VERSION}"
    puts "Rails project detected: #{is_rails ? 'Yes' : 'No'}"

    unused, problematic, large, all_files = find_unused_files

    display_results(unused, problematic, large, all_files)
    handle_interactive_selection(unused)
  end

  private

  def check_ruby_version
    if Gem::Version.new(RUBY_VERSION) < Gem::Version.new(REQUIRED_RUBY_VERSION)
      puts "Warning: This script is designed for Ruby #{REQUIRED_RUBY_VERSION} and above. You're running Ruby #{RUBY_VERSION}."
      puts "Some features may not work as expected."
    end
  end

  def detect_rails
    File.exist?('config/application.rb')
  end

  def load_config
    YAML.load_file(CONFIG_FILE) rescue DEFAULT_CONFIG
  end

  def parse_options
    options = {}
    OptionParser.new do |opts|
      opts.banner = "Usage: ruby_rubble.rb [options]"
      opts.on("-d", "--dry-run", "Perform a dry run without making changes") do |v|
        options[:dry_run] = v
      end
    end.parse!
    options
  end

  def find_unused_files
    used_files = Set.new
    all_files = {}
    problematic_requires = Set.new
    large_files = Set.new

    ignore_patterns = parse_gitignore(app_directory)
    current_script = File.expand_path(__FILE__)

    files = Dir.glob(File.join(app_directory, '**', '*'))
    progress_bar = ProgressBar.create(total: files.size, format: '%a %b\u{15E7}%i %p%% %t')

    files.each do |file_path|
      next if File.directory?(file_path)
      next if should_ignore?(file_path, ignore_patterns)
      next unless config['extensions'].include?(File.extname(file_path))
      next if config['exclude_self'] && file_path == current_script

      file_info = get_file_info(file_path)
      all_files[file_path] = file_info
      progress_bar.increment  # Increment progress bar here

      large_files.add(file_path) if file_info[:size] > config['size_threshold']

      if (config['main_files'] || []).include?(File.basename(file_path)) ||
         (is_rails && (file_path.include?('app/') || file_path.include?('lib/')))
        used_files.add(file_path)
        begin
          required_files = get_required_files(file_path)
          required_files.each do |required_file|
            full_path = File.expand_path(required_file, File.dirname(file_path))
            used_files.add(full_path)
            used_files.add(File.join(app_directory, "#{required_file}.rb"))
          end
        rescue => e
          problematic_requires.add([file_path, e.message])
          log_error("Failed to perform operation", e)
        end
      end
    end

    unused_files = all_files.keys.to_set - used_files
    [unused_files, problematic_requires, large_files, all_files]
  end


  def parse_gitignore(directory)
    gitignore_path = File.join(directory, '.gitignore')
    return [] unless File.exist?(gitignore_path)

    File.readlines(gitignore_path).map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
  end

  private

  def should_ignore?(file_path, ignore_patterns)
    rel_path = relative_path(file_path, app_directory)
    puts "Debug: file_path = #{file_path}, rel_path = #{rel_path}"
    puts "Debug: ignore_patterns = #{ignore_patterns.inspect}"

    return false if File.basename(file_path) == 'app.rb'
    return true if config['ignore_dirs'].any? { |ignore| rel_path.start_with?(ignore) }

    ignore_patterns.each do |pattern|
      # Adjust the pattern to match directories correctly
      adjusted_pattern = pattern.end_with?('/') ? "#{pattern}**" : pattern
      match = File.fnmatch?(adjusted_pattern, rel_path)
      puts "Debug: pattern = #{pattern}, adjusted_pattern = #{adjusted_pattern}, match = #{match}"
      return true if match
    end

    false
  end

  def relative_path(path, start)
    path = File.expand_path(path)
    start = File.expand_path(start)
    Pathname.new(path).relative_path_from(Pathname.new(start)).to_s
  end


  def get_required_files(file_path)
    content = File.read(file_path)
    requires = content.scan(/require(?:_relative)?\s+['"](.+?)['"]/).flatten
    requires += content.scan(/class\s+(\w+)/).flatten.map { |c| c.gsub(/(?<!^)([A-Z])/, '_\1').downcase } if is_rails
    requires
  end

  def get_file_info(file_path)
    stat = File.stat(file_path)
    {
      size: stat.size,
      created: stat.ctime,
      modified: stat.mtime
    }
  end

  def format_size(size)
    units = %w[B KB MB GB TB]
    unit_index = 0
    while size >= 1024 && unit_index < units.length - 1
      size /= 1024.0
      unit_index += 1
    end
    format("%.2f %s", size, units[unit_index])
  end

  def format_date(date)
    return date.strftime("%I:%M %p") if date.to_date == Date.today
    date.strftime("%A, %b %d, %Y")
  end

  def print_table(title, headers, rows, widths)
    puts "\n#{title}:"
    puts "┌" + widths.map { |w| "─" * (w + 2) }.join("┬") + "┐"
    puts "│ " + headers.zip(widths).map { |h, w| h.ljust(w) }.join(" │ ") + " │"
    puts "├" + widths.map { |w| "─" * (w + 2) }.join("┼") + "┤"
    rows.each do |row|
      puts "│ " + row.zip(widths).map { |c, w| c.to_s.ljust(w) }.join(" │ ") + " │"
    end
    puts "└" + widths.map { |w| "─" * (w + 2) }.join("┴") + "┘"
  end

  def display_results(unused, problematic, large, all_files)
    if unused.any?
      unused_rows = unused.map do |file|
        [
          relative_path(file, app_directory),
          format_size(all_files[file][:size]),
          format_date(all_files[file][:created]),
          format_date(all_files[file][:modified])
        ]
      end
      print_table(
        "🕵️ The Gem Graveyard (aka Unused Files) 🕵️",
        ["File", "Size", "Created", "Last Modified"],
        unused_rows,
        [40, 10, 25, 25]
      )
    else
      puts "No unused files found. Your codebase is cleaner than a freshly polished Ruby! ✨"
    end

    if problematic.any?
      problematic_rows = problematic.to_a
      print_table(
        "🚨 The 'gem install' Wall of Shame 🚨",
        ["File", "Error"],
        problematic_rows,
        [30, 50]
      )
    end

    if large.any?
      large_rows = large.map { |file| [relative_path(file, app_directory), format_size(all_files[file][:size])] }
      print_table(
        "🐘 Monolithic Monstrosities (Files over #{format_size(config['size_threshold'])}) 🐘",
        ["File", "Size"],
        large_rows,
        [60, 20]
      )
    end
  end

  def handle_interactive_selection(unused)
    return unless unused.any?

    relative_paths = unused.map { |file| relative_path(file, app_directory) }
    puts "\nTime to decide the fate of these digital tumbleweeds."
    puts "Remember: To delete or not to delete, that is the question - whether 'tis nobler in the RAM to suffer..."

    # Store previous output
    previous_output = `stty size`.split.map(&:to_i).reverse.inject(:*)
    previous_output = `tput lines`.to_i if previous_output.zero?
    previous_output = `tput cols`.to_i if previous_output.zero?

    result = interactive_select(relative_paths, previous_output)

    return if result.nil?

    selected_files, action = result
    files_to_process = selected_files.map { |file| File.join(app_directory, file) }

    return if files_to_process.empty?

    puts "\nFiles selected for the great #{action}:"
    files_to_process.each { |file| puts "- #{file}" }

    print "\nAre you sure you want to #{action} these files? This action is more permanent than a Ruby constant. (Y/N): "
    confirm = STDIN.gets.chomp.downcase
    if confirm == 'y'
      if action == 'delete'
        puts "\nPreparing to send these files to the great `/dev/null` in the sky:"
        files_to_process.each { |file| puts "File.delete('#{file}')  # Sayonara, old friend" }

        print "\nFinal confirmation. Proceed with the digital exorcism? (Y/N): "
        final_confirm = STDIN.gets.chomp.downcase
        if final_confirm == 'y'
          delete_files(files_to_process)
          puts "\n🧹 Clean-up complete! Your codebase is now lighter than a single-line Ruby quine. 🌬️"
        else
          puts "\nDeletion cancelled. Your files will live to raise NameErrors another day."
        end
      elsif action == 'archive'
        puts "\nPreparing to send these files to #{archive_path} - where code goes to contemplate its existence."
        print "\nFinal confirmation. Proceed with the grand archiving? (Y/N): "
        final_confirm = STDIN.gets.chomp.downcase
        if final_confirm == 'y'
          move_to_archive(files_to_process, archive_path)
          puts "\n📦 Archiving complete! Your files have been safely tucked away, like private methods in a well-designed class."
        else
          puts "\nArchiving cancelled. Your files will remain unenlightened about their unused status."
        end
      end
    else
      puts "\n#{action.capitalize} cancelled. Your digital clutter will continue to spark joy and confusion in equal measure."
    end
  end

  def interactive_select(options, previous_output)
    selected = Array.new(options.length, false)
    current = 0

    loop do
      # Move cursor to the beginning of the terminal and overwrite the existing content
      print "\033[2J\033[H"

      # Print previous output
      puts "\033[#{previous_output}A"

      puts "Use ↑ and ↓ to move, SPACE to select/deselect, 'a' to select all, 'n' to deselect all"
      puts "'q' to quit, 'd' to delete selected, 'm' to move selected to archive"
      puts "=" * 50
      options.each_with_index do |option, index|
        prefix = index == current ? '> ' : '  '
        checkbox = selected[index] ? '[x]' : '[ ]'
        puts "#{prefix}#{checkbox} #{option}"
      end
      puts "\nSelected files: #{selected.count(true)}"

      key = get_char
      case key
      when "\e"
        next_two = get_char + get_char
        case next_two
        when '[A' then current = (current - 1) % options.length  # Up arrow
        when '[B' then current = (current + 1) % options.length  # Down arrow
        end
      when ' ' then selected[current] = !selected[current]  # Space bar
      when 'a' then selected.fill(true)
      when 'n' then selected.fill(false)
      when 'q' then return nil
      when 'd' then return [options.select.with_index { |_, i| selected[i] }, 'delete']
      when 'm' then return [options.select.with_index { |_, i| selected[i] }, 'archive']
      end
    end
  end

  def get_char
    state = `stty -g`
    `stty raw -echo -icanon isig`
    STDIN.getc.chr
  ensure
    `stty #{state}`
  end

  def delete_files(files_to_delete)
    files_to_delete.each do |file|
      begin
        if options[:dry_run]
          puts "[DRY RUN] Would delete: #{file}"
        else
          File.delete(file)
          puts "Deleted: #{file}"
        end
      rescue => e
        puts "Error deleting #{file}: #{e.message}"
        log_error("Failed to perform operation", e)
      end
    end
  end

  def move_to_archive(files_to_move, archive_folder)
    FileUtils.mkdir_p(archive_folder) unless Dir.exist?(archive_folder) || options[:dry_run]
    files_to_move.each do |file|
      begin
        if options[:dry_run]
          puts "[DRY RUN] Would move to archive: #{file}"
        else
          FileUtils.mv(file, File.join(archive_folder, File.basename(file)))
          puts "Moved to archive: #{file}"
        end
      rescue => e
        puts "Error moving #{file} to archive: #{e.message}"
        log_error("Failed to perform operation", e)
      end
    end
  end

  def log_error(message, exception = nil)
    puts "Error: #{message}"
    puts "Exception: #{exception.message}" if exception
    puts exception.backtrace.join("\n") if exception && $DEBUG
  end
end

if __FILE__ == $PROGRAM_NAME
  app_directory = Dir.pwd
  rubyrubble = RubyRubble.new(app_directory)
  rubyrubble.run
end
