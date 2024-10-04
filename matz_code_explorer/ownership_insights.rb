#!/usr/bin/env ruby
# ownership_insights.rb

require 'json'
require 'open3'
require 'optparse'
require 'colorize'
require 'parallel'
require 'fileutils'
require 'terminal-table'

# Provides basic info for the menu
def menu_info
  {
    title: "Ownership Insights",
    description: "Analyzes code contributions by author."
  }
end

# Handle the '--info' flag
if ARGV.include?('--info')
  info = menu_info
  puts info[:title].green.bold
  puts info[:description].cyan
  exit
end

# Validate that the provided directory is a Git repository
def validate_git_repository(target_dir)
  target_dir = File.expand_path(target_dir)
  unless Dir.exist?(target_dir) && system("git -C #{target_dir} rev-parse --is-inside-work-tree > /dev/null 2>&1")
    puts "Error: Not inside a valid Git repository.".red
    exit 1
  end
end

# Fetches all Ruby files from the given directory, excluding specific folders
def fetch_ruby_files(target_dir)
  excluded_dirs = ['scripts/', 'node_modules/', 'vendor/', 'tmp/', 'log/', 'public/packs/', 'coverage/', 'dist/', 'build/']
  ruby_files = `git -C #{target_dir} ls-files --full-name '*.rb' 2>/dev/null`.split("\n").reject do |file|
    excluded_dirs.any? { |dir| file.start_with?(dir) }
  end
  ruby_files
end

# Progress report for entire script
def report_progress_overall(stage, index, total)
  percentage = ((index + 1).to_f / total * 100).round(2)
  progress_bar = "[" + "#" * ((percentage / 10).round) + "-" * (10 - (percentage / 10).round) + "]"
  progress = "#{stage}: #{index + 1}/#{total} files #{progress_bar} #{percentage}%"
  print "\r#{progress.ljust(100)}"
  $stdout.flush
end

# Caches blame data for Ruby files
def cache_git_blame_data(ruby_files, target_dir)
  blame_data = {}

  ruby_files.each_with_index do |file, index|
    report_progress_overall("Caching blame data", index, ruby_files.size)
    # Check if file is tracked by Git before running blame
    tracked = system("git -C #{target_dir} ls-files --error-unmatch #{file} > /dev/null 2>&1")
    unless tracked
      puts "\nFile #{file} is not tracked by Git. Marking as 'Uncommitted Changes'.".yellow
      blame_data[file] = "author Uncommitted Changes\n"
      next
    end

    stdout, stderr, status = Open3.capture3("git -C #{target_dir} blame --line-porcelain -- #{file} 2>/dev/null")
    if status.success?
      blame_data[file] = stdout
    else
      puts "\nFailed to run git blame on #{file}. #{stderr.strip}. Attempting to use git log to get author information...".yellow
      log_output, log_error, log_status = Open3.capture3("git -C #{target_dir} log -1 --pretty=format:%an -- #{file} 2>/dev/null")
      if log_status.success? && !log_output.strip.empty?
        blame_data[file] = "author #{log_output.strip}\n"
      else
        puts "\nFailed to get author information for #{file} using git log. Marking as 'Uncommitted Changes'.".yellow
        blame_data[file] = "author Uncommitted Changes\n"
      end
    end
  end

  blame_data
end

# Calculates author statistics based on blame data
def calculate_author_stats(ruby_files, blame_data)
  author_stats = Hash.new(0)
  file_count_by_author = Hash.new(0)

  ruby_files.each_with_index do |file, index|
    report_progress_overall("Analyzing author stats", index, ruby_files.size)
    next unless blame_data[file]
    blame_data[file].each_line do |line|
      if line.start_with?("author ")
        author = line.split(' ', 2).last.strip
        author_stats[author] += 1
        file_count_by_author[author] += 1
      end
    end
  end

  { author_stats: author_stats, file_count_by_author: file_count_by_author }
end

# Displays author statistics in a tabular format
def display_author_stats(author_stats, file_count_by_author)
  if author_stats.empty?
    puts "\nNo ownership data found. Perhaps it's time to foster more collaboration, just like the quiet cooperation that creates harmony in a garden.".yellow
  else
    puts "\nCode ownership by author:".cyan.bold
    sorted_authors = author_stats.sort_by { |_, count| -count }
    total_lines = author_stats.values.sum
    table = Terminal::Table.new do |t|
      t.title = "Code Ownership by Author"
      t.headings = ['Author', 'Lines', 'Percentage', 'Files']
      sorted_authors.each do |author, count|
        percentage = (count.to_f / total_lines * 100).round(2)
        t << [author.cyan, count.to_s.green, "#{percentage}%".yellow, file_count_by_author[author].to_s.magenta]
      end
    end
    puts table
    puts "Actionable Insight: Encourage authors with low contributions to collaborate more. Consider mentoring or pairing sessions to ensure knowledge distribution.\n".cyan
  end
end

# Calculates complexity of files by author
def calculate_complexity_by_author(ruby_files, target_dir)
  complexity_by_author = Hash.new { |h, k| h[k] = [] }

  Parallel.each_with_index(ruby_files, in_threads: 4) do |file, index|
    report_progress_overall("Analyzing complexity", index, ruby_files.size)
    next unless File.file?(File.expand_path(file, target_dir))

    complexity_output = `flog #{File.expand_path(file, target_dir)} 2>&1`
    complexity = complexity_output[/\d+/]&.to_i
    if complexity.nil?
      puts "\nCould not calculate complexity for #{file}. Complexity, like many things in life, can be elusive and that's okay.".yellow
      next
    end

    author = `git -C #{target_dir} log -1 --pretty=format:%an -- #{file} 2>/dev/null`.strip
    if author.empty?
      author = "Uncommitted Changes"
    end

    complexity_by_author[author] << complexity
  end

  complexity_by_author
end

# Displays complexity by author in a tabular format
def display_complexity_by_author(complexity_by_author)
  puts "\nFile complexity distribution by author:".cyan.bold
  table = Terminal::Table.new do |t|
    t.title = "File Complexity by Author"
    t.headings = ['Author', 'Average Complexity']
    complexity_by_author.each do |author, complexities|
      avg_complexity = complexities.sum.to_f / complexities.size
      t << [author.cyan, avg_complexity.round(2).to_s.green]
    end
  end
  puts table
  puts "Actionable Insight: High average complexity may indicate areas where refactoring could help. Encourage authors to reduce complexity to improve maintainability.\n".cyan
end

# Calculates commit activity by author
def calculate_commit_activity(ruby_files, target_dir)
  commit_activity_by_author = Hash.new(0)

  ruby_files.each_with_index do |file, index|
    report_progress_overall("Analyzing commit activity", index, ruby_files.size)
    next unless File.file?(File.expand_path(file, target_dir))

    commits_output = `git -C #{target_dir} log --pretty=format:%an -- #{file} 2>/dev/null`
    commits_output.each_line do |line|
      author = line.strip
      commit_activity_by_author[author] += 1
    end
  end

  commit_activity_by_author
end

# Displays commit activity by author in a tabular format
def display_commit_activity_by_author(commit_activity_by_author)
  puts "\nCommit activity by author:".cyan.bold
  table = Terminal::Table.new do |t|
    t.title = "Commit Activity by Author"
    t.headings = ['Author', 'Commits']
    commit_activity_by_author.each do |author, commits|
      t << [author.cyan, commits.to_s.green]
    end
  end
  puts table
  puts "Actionable Insight: Authors with high commit activity are contributing frequently. This can indicate high engagement but also potential code churn. Review their commits to ensure quality over quantity.".cyan
end

options = {}
option_parser = OptionParser.new do |opts|
  opts.banner = "Usage: ownership_insights.rb [options]"

  opts.on("-dDIR", "--directory=DIR", "Target directory to analyze") do |dir|
    options[:directory] = dir
  end

  opts.on("-h", "--help", "Displays Help") do
    puts opts
    exit
  end
end
temp_files = []

begin
  option_parser.parse!
  Signal.trap("INT") do
    puts "\nExecution interrupted by user. Cleaning up temporary files and exiting gracefully...".red
    temp_files.each do |file|
      FileUtils.rm_f(file) if File.exist?(file)
    end
    exit 0
  end
rescue OptionParser::InvalidOption, OptionParser::MissingArgument
  puts option_parser.help
  exit
end

if ARGV.empty? && options.empty?
  puts option_parser.help
  exit
end

target_dir = options[:directory]

if target_dir.nil?
  if ARGV.length == 1 && Dir.exist?(File.expand_path(ARGV[0]))
    target_dir = File.expand_path(ARGV[0])
  else
    puts option_parser.help
    exit
  end
end

unless Dir.exist?(target_dir)
  puts "Error: Directory '#{target_dir}' does not exist.".red
  exit 1
end

validate_git_repository(target_dir)
ruby_files = fetch_ruby_files(target_dir)
if ruby_files.empty? && File.expand_path(target_dir) == Dir.pwd
  puts "No Ruby files found for analysis in the current directory.".yellow
  exit
end
ruby_files.uniq!

if ruby_files.empty?
  puts "No Ruby files found for ownership analysis.".yellow
  exit
end

puts "\nStarting code ownership and complexity analysis...\n".cyan.bold
blame_data = cache_git_blame_data(ruby_files, target_dir)
author_stats, file_count_by_author = calculate_author_stats(ruby_files, blame_data).values_at(:author_stats, :file_count_by_author)
display_author_stats(author_stats, file_count_by_author)

complexity_by_author = calculate_complexity_by_author(ruby_files, target_dir)
display_complexity_by_author(complexity_by_author)

commit_activity_by_author = calculate_commit_activity(ruby_files, target_dir)
display_commit_activity_by_author(commit_activity_by_author)

puts "\n===================================\n".yellow.bold

# Cleanup temporary files if any remain
temp_files.each do |file|
  FileUtils.rm_f(file) if File.exist?(file)
end
