#!/usr/bin/env ruby
require 'json'
require 'open3'

def git_blame_stats(target_dir)
  puts "=== Ownership Insights ==="
  Dir.chdir(target_dir)

  # Check if inside a Git repository
  unless system('git rev-parse --is-inside-work-tree > /dev/null 2>&1')
    puts "Not inside a Git repository."
    return
  end

  # Define excluded directories
  excluded_dirs = ['scripts/', 'node_modules/', 'vendor/', 'tmp/', 'log/', 'public/packs/', 'coverage/', 'dist/', 'build/']

  # Get list of Ruby files excluding common directories
  ruby_files = `git ls-files '*.rb'`.split("\n").reject do |file|
    excluded_dirs.any? { |dir| file.start_with?(dir) }
  end

  if ruby_files.empty?
    puts "No Ruby files found for ownership analysis."
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
    puts "No ownership data found."
  else
    sorted_authors = author_stats.sort_by { |_, count| -count }
    sorted_authors.each do |author, count|
      puts "#{author}: #{count} lines"
    end
  end

  puts "============================"
end

# Main Execution
if __FILE__ == $0
  target_dir = ARGV[0] || Dir.pwd
  unless Dir.exist?(target_dir)
    puts "Error: Directory '#{target_dir}' does not exist."
    exit 1
  end

  git_blame_stats(target_dir)
end
