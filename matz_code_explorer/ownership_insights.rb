#!/usr/bin/env ruby
# ownership_insights.rb

require 'json'
require 'open3'
require 'optparse'
require 'colorize'

def menu_info
  {
    title: "Ownership Insights",
    description: "Analyzes code contributions by author."
  }
end

# Handle the '--info' flag
if ARGV.include?('--info')
  info = menu_info
  puts info[:title]
  puts info[:description]
  exit
end


puts "Ownership Insights: Analyzes code contributions by author.".cyan
puts "This helps understand the distribution of knowledge and responsibilities within the project.".cyan
puts ""

def git_blame_stats(target_dir)
	puts "=== Ownership Insights: A Tale of Code and Creators ===".yellow.bold
  Dir.chdir(target_dir) do
    # Check if inside a Git repository
    unless system('git rev-parse --is-inside-work-tree > /dev/null 2>&1')
      puts "Not inside a Git repository.".red
      return
    end

    # Define excluded directories
    excluded_dirs = ['scripts/', 'node_modules/', 'vendor/', 'tmp/', 'log/', 'public/packs/', 'coverage/', 'dist/', 'build/']

    # Get list of Ruby files excluding common directories
    ruby_files = `git ls-files '*.rb'`.split("\n").reject do |file|
      excluded_dirs.any? { |dir| file.start_with?(dir) }
    end

    if ruby_files.empty?
      puts "No Ruby files found for ownership analysis.".yellow
      return
    end

    author_stats = Hash.new(0)

    ruby_files.each do |file|
      stdout, _stderr, _status = Open3.capture3("git blame --line-porcelain #{file}")
      stdout.each_line do |line|
        if line.start_with?("author ")
          author = line.split(' ', 2).last.strip
          author_stats[author] += 1
        end
      end
    end

    if author_stats.empty?
      puts "No ownership data found.".yellow
    else
      puts "\nCode ownership by author:".cyan
      sorted_authors = author_stats.sort_by { |_, count| -count }
      total_lines = author_stats.values.sum
      sorted_authors.each do |author, count|
        percentage = (count.to_f / total_lines * 100).round(2)
        puts "#{author}: #{count} lines (#{percentage}%)".green
      end
    end
  end

  # File ownership distribution
  puts "\nFile ownership distribution:".cyan
  ownership_distribution = `git ls-tree -r HEAD | cut -f2 | xargs -n1 git blame --line-porcelain HEAD | grep "^author " | sort | uniq -c | sort -nr`
  ownership_distribution.each_line do |line|
    puts line.strip.green
  end

  # File complexity distribution by author
  puts "\nFile complexity distribution by author:".cyan
  ruby_files = Dir.glob('**/*.rb')
  complexity_by_author = Hash.new { |h, k| h[k] = [] }
  ruby_files.each do |file|
    next unless File.file?(file)
    complexity = `flog #{file}`.to_i
    author = `git log -1 --pretty=format:%an #{file}`.strip
    complexity_by_author[author] << complexity
  end

  complexity_by_author.each do |author, complexities|
    avg_complexity = complexities.sum.to_f / complexities.size
    puts "#{author}: Average complexity #{avg_complexity.round(2)}".green
  end
puts "===================================".yellow.bold
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ownership_insights.rb [options]"

  opts.on("-dDIR", "--directory=DIR", "Target directory to analyze") do |dir|
    options[:directory] = dir
  end

  opts.on("-h", "--help", "Displays Help") do
    puts opts
    exit
  end
end.parse!

target_dir = options[:directory] || Dir.pwd

unless Dir.exist?(target_dir)
  puts "Error: Directory '#{target_dir}' does not exist.".red
  exit 1
end

git_blame_stats(target_dir)
