#!/usr/bin/env ruby
require 'json'
require 'bundler'
require 'optparse'
require 'colorize'

# Ensure 'colorize' gem is installed
begin
  require 'colorize'
rescue LoadError
  puts "Installing 'colorize' gem..."
  system('gem install colorize')
  Gem.clear_paths
  require 'colorize'
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: dependency_analysis.rb [options]"

  opts.on("-dDIR", "--directory=DIR", "Target directory to analyze") do |dir|
    options[:directory] = dir
  end

  opts.on("-iPATTERN", "--ignore=PATTERN", "Additional ignore pattern (can be used multiple times)") do |pattern|
    options[:ignore] ||= []
    options[:ignore] << pattern
  end

  opts.on("-h", "--help", "Displays Help") do
    puts opts
    exit
  end
end.parse!

target_dir = options[:directory] || Dir.pwd
additional_ignores = options[:ignore] || []

unless Dir.exist?(target_dir)
  puts "Error: Directory '#{target_dir}' does not exist.".red
  exit 1
end

# Function to handle ignore patterns
def ignored?(file, ignore_patterns)
  ignore_patterns.any? do |pattern|
    File.fnmatch?(pattern, file, File::FNM_PATHNAME | File::FNM_DOTMATCH)
  end
end

puts "=== Dependency Analysis for #{target_dir} ===".yellow.bold

# Gather all ignore patterns
ignore_patterns = additional_ignores

# Analyze Bundler dependencies
def analyze_bundler(target_dir, ignore_patterns)
  gemfile = File.join(target_dir, 'Gemfile')
  if File.exist?(gemfile) && !ignored?(gemfile, ignore_patterns)
    puts "$(tput setaf 3)=== Bundler Dependencies ===$(tput sgr0)"
    Bundler.with_clean_env do
      begin
        bundler = Bundler.load
        if bundler.dependencies.empty?
          puts "No Bundler dependencies found.".cyan
        else
          bundler.dependencies.each do |dep|
            version = dep.requirement
            puts " - #{dep.name} (#{version})".green
          end
        end
      rescue => e
        puts "Error loading Gemfile: #{e.message}".red
      end
    end
  else
    puts "Gemfile not found or ignored.".red
  end
end

# Analyze Gemspec dependencies
def analyze_gemspec(target_dir, ignore_patterns)
  gemspec_files = Dir.glob(File.join(target_dir, '*.gemspec')).reject { |file| ignored?(file, ignore_patterns) }
  if gemspec_files.empty?
    puts "$(tput setaf 3)=== Gemspec Dependencies ===$(tput sgr0)"
    puts "No gemspec files found.".red
  else
    gemspec_files.each do |gemspec|
      puts "$(tput setaf 3)=== Dependencies in #{File.basename(gemspec)} ===$(tput sgr0)"
      File.readlines(gemspec).each do |line|
        if line.strip.start_with?("spec.add_dependency", "spec.add_runtime_dependency")
          # Extract dependency name and version
          if line =~ /spec\.add_(?:runtime_)?dependency\s+['"]([^'"]+)['"],\s*['"]([^'"]+)['"]/
            dep_name = Regexp.last_match(1)
            dep_version = Regexp.last_match(2)
            puts " - #{dep_name} (#{dep_version})".green
          else
            puts " - #{line.strip}".yellow
          end
        end
      end
    end
  end
end

# Analyze package.json dependencies
def analyze_package_json(target_dir, ignore_patterns)
  package_json = File.join(target_dir, 'package.json')
  if File.exist?(package_json) && !ignored?(package_json, ignore_patterns)
    puts "$(tput setaf 3)=== NPM/Yarn Dependencies ===$(tput sgr0)"
    begin
      data = JSON.parse(File.read(package_json))
      ['dependencies', 'devDependencies'].each do |type|
        next unless data[type]
        puts "\n#{type.capitalize}:".blue.bold
        data[type].each do |name, version|
          puts " - #{name} (#{version})".green
        end
      end
    rescue JSON::ParserError => e
      puts "Error parsing package.json: #{e.message}".red
    end
  else
    puts "package.json not found or ignored.".red
  end
end

# Execute analyses
analyze_bundler(target_dir, ignore_patterns)
analyze_gemspec(target_dir, ignore_patterns)
analyze_package_json(target_dir, ignore_patterns)

puts "=========================================".yellow.bold
