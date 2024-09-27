#!/usr/bin/env ruby
# dependency_analysis.rb

require 'json'
require 'bundler'
require 'optparse'
require 'colorize'

def menu_info
  {
    title: "Dependency Analysis",
    description: "Examines project dependencies and versions."
  }
end

# Handle the '--info' flag
if ARGV.include?('--info')
  info = menu_info
  puts info[:title]
  puts info[:description]
  exit
end


puts "Dependency Analysis: Examines project dependencies and versions.".cyan
puts "This helps manage external libraries and identify potential conflicts or outdated packages.".cyan
puts ""

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: dependency_analysis.rb [options]"

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

puts "=== Dependency Analysis ===".yellow.bold

Dir.chdir(target_dir) do
  # Analyze Bundler dependencies
  if File.exist?('Gemfile')
    puts "Bundler Dependencies:".cyan
    begin
      Bundler.with_unbundled_env do
        bundler = Bundler.load
        if bundler.dependencies.empty?
          puts "  No Bundler dependencies found.".yellow
        else
          bundler.dependencies.each do |dep|
            puts "  - #{dep.name} (#{dep.requirement})".green
          end
        end
      end
    rescue => e
      puts "  Error loading Gemfile: #{e.message}".red
    end
  else
    puts "Gemfile not found.".yellow
  end

  # Analyze Gemspec dependencies
  gemspec_files = Dir.glob('*.gemspec')
  if gemspec_files.any?
    puts "\nGemspec Dependencies:".cyan
    gemspec_files.each do |gemspec|
      puts "  #{File.basename(gemspec)}:".cyan
      File.readlines(gemspec).each do |line|
        if line =~ /add_(?:development_|runtime_)?dependency/
          puts "  - #{line.strip}".green
        end
      end
    end
  else
    puts "\nNo gemspec files found.".yellow
  end

puts "===================================".yellow.bold
end
