#!/usr/bin/env ruby

require 'set'
require 'fileutils'
require 'date'

# Version check and compatibility
REQUIRED_RUBY_VERSION = '2.5.0'
if Gem::Version.new(RUBY_VERSION) < Gem::Version.new(REQUIRED_RUBY_VERSION)
  puts "Warning: This script is designed for Ruby #{REQUIRED_RUBY_VERSION} and above. You're running Ruby #{RUBY_VERSION}."
  puts "Some features may not work as expected."
end

puts "Running RubyRubble with Ruby #{RUBY_VERSION}"

# Detect Rails
IS_RAILS = File.exist?('config/application.rb')
puts "Rails project detected: #{IS_RAILS ? 'Yes' : 'No'}"

# Configuration options
CONFIG = {
  'MAIN_FILES' => IS_RAILS ? ['config/application.rb'] : ['app.rb', 'main.rb', 'Gemfile'],
  'IGNORE_DIRS' => IS_RAILS ? %w[vendor .git .bundle tmp log public] : %w[vendor .git .bundle],
  'EXTENSIONS' => IS_RAILS ? %w[.rb .rake .erb .haml .slim] : %w[.rb],
  'SIZE_THRESHOLD' => 1024 * 1024,
  'EXCLUDE_SELF' => true,
  'ARCHIVE_FOLDER' => 'Matz_Museum'
}

def parse_gitignore(directory)
  gitignore_path = File.join(directory, '.gitignore')
  return [] unless File.exist?(gitignore_path)

  File.readlines(gitignore_path).map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
end

def relative_path(path, start)
  path = File.expand_path(path)
  start = File.expand_path(start)

  path_parts = path.split(File::SEPARATOR)
  start_parts = start.split(File::SEPARATOR)

  while !path_parts.empty? && !start_parts.empty? && path_parts.first == start_parts.first
    path_parts.shift
    start_parts.shift
  end

  return '.' if path_parts.empty? && start_parts.empty?

  relative = '../' * start_parts.size + path_parts.join(File::SEPARATOR)
  relative.empty? ? '.' : relative
end

def should_ignore?(file_path, ignore_patterns, standard_ignores)
  rel_path = relative_path(file_path, Dir.pwd)

  return true if standard_ignores.any? { |ignore| rel_path.start_with?(ignore) }

  ignore_patterns.any? { |pattern| File.fnmatch?(pattern, rel_path) }
end

def get_required_files(file_path)
  content = File.read(file_path)
  requires = content.scan(/require(?:_relative)?\s+['"](.+?)['"]/).flatten
  # Add support for Rails autoloading
  requires += content.scan(/class\s+(\w+)/).flatten.map { |c| c.gsub(/(?<!^)([A-Z])/, '_\1').downcase } if IS_RAILS
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

def find_unused_files(directory)
  used_files = Set.new
  all_files = {}
  problematic_requires = Set.new
  large_files = Set.new

  ignore_patterns = parse_gitignore(directory)
  current_script = File.expand_path(__FILE__)

  Dir.glob(File.join(directory, '**', '*')).each do |file_path|
    next if File.directory?(file_path)
    next if should_ignore?(file_path, ignore_patterns, CONFIG['IGNORE_DIRS'])
    next unless CONFIG['EXTENSIONS'].include?(File.extname(file_path))
    next if CONFIG['EXCLUDE_SELF'] && file_path == current_script

    file_info = get_file_info(file_path)
    all_files[file_path] = file_info

    large_files.add(file_path) if file_info[:size] > CONFIG['SIZE_THRESHOLD']

    if CONFIG['MAIN_FILES'].include?(File.basename(file_path)) ||
       (IS_RAILS && (file_path.include?('app/') || file_path.include?('lib/')))
      used_files.add(file_path)
      begin
        required_files = get_required_files(file_path)
        required_files.each do |required_file|
          full_path = File.expand_path(required_file, File.dirname(file_path))
          used_files.add(full_path)
        end
      rescue => e
        problematic_requires.add([file_path, e.message])
      end
    end
  end

  unused_files = all_files.keys.to_set - used_files
  [unused_files, problematic_requires, large_files, all_files]
end

def get_char
  state = `stty -g`
  `stty raw -echo -icanon isig`
  STDIN.getc.chr
ensure
  `stty #{state}`
end

def interactive_select(options)
  selected = Array.new(options.length, false)
  current = 0

  loop do
    system('clear') || system('cls')
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

def delete_files(files_to_delete)
  files_to_delete.each do |file|
    begin
      File.delete(file)
      puts "Deleted: #{file}"
    rescue => e
      puts "Error deleting #{file}: #{e.message}"
    end
  end
end

def move_to_archive(files_to_move, archive_folder)
  FileUtils.mkdir_p(archive_folder) unless Dir.exist?(archive_folder)
  files_to_move.each do |file|
    begin
      FileUtils.mv(file, File.join(archive_folder, File.basename(file)))
      puts "Moved to archive: #{file}"
    rescue => e
      puts "Error moving #{file} to archive: #{e.message}"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  app_directory = Dir.pwd
  archive_path = File.join(app_directory, CONFIG['ARCHIVE_FOLDER'])

  puts "💎 RubyRubble: Where 'require' meets 'retire' 💎"
  puts "Untangling the Gordian knot of unused code in: #{app_directory}"
  puts "Archive location: #{archive_path}"
  puts "Channeling our inner Matz to separate the gems from the rocks..."

  unused, problematic, large, all_files = find_unused_files(app_directory)

  if unused.any?
    unused_rows = unused.map do |file|
      [
        File.relative_path(file, app_directory),
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
    large_rows = large.map { |file| [File.relative_path(file, app_directory), format_size(all_files[file][:size])] }
    print_table(
      "🐘 Monolithic Monstrosities (Files over #{format_size(CONFIG['SIZE_THRESHOLD'])}) 🐘",
      ["File", "Size"],
      large_rows,
      [60, 20]
    )
  end

  puts "\n⚠️ Disclaimer: Use with the caution of a seasoned Rubyist handling meta-programming! ⚠️"
  puts "This script is like a well-intentioned but slightly nearsighted code reviewer."
  puts "It might mistake your 'Convention over Configuration' for 'Confusion over Convolution'."

  if unused.any?
    relative_paths = unused.map { |file| File.relative_path(file, app_directory) }
    puts "\nTime to decide the fate of these digital tumbleweeds."
    puts "Remember: To delete or not to delete, that is the question - whether 'tis nobler in the RAM to suffer..."
    result = interactive_select(relative_paths)

    if result.nil?
      puts "Operation cancelled faster than a failed CI build. No files were harmed in the making of this decision."
      exit
    end

    selected_files, action = result
    files_to_process = selected_files.map { |file| File.join(app_directory, file) }

    if files_to_process.empty?
      puts "No files selected. Your codebase remains as mysterious as a poorly documented gem."
      exit
    end

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
  else
    puts "\nNo unused files to process. Your codebase is already more minimalist than `puts 'Hello World'`."
  end

  puts "\nRemember: Today's 'unused' file might be tomorrow's 'gem of the year'! 💎🚀"
end
