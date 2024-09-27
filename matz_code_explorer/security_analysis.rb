#!/usr/bin/env ruby
# security_analysis.rb

require 'optparse'
require 'colorize'

def menu_info
  {
    title: "Security Analysis",
    description: "Checks for potential security vulnerabilities."
  }
end

# Handle the '--info' flag
if ARGV.include?('--info')
  info = menu_info
  puts info[:title]
  puts info[:description]
  exit
end

puts "Security Analysis: Checks for potential security vulnerabilities.".cyan
puts "This helps identify and address security risks in the codebase.".cyan
puts ""

options = { ignore_patterns: [] }
OptionParser.new do |opts|
  opts.banner = "Usage: security_analysis.rb [options]"

  opts.on("-dDIR", "--directory=DIR", "Target directory to analyze") do |dir|
    options[:directory] = dir
  end

  opts.on("-i", "--ignore PATTERN", "Add an ignore pattern") do |pattern|
    options[:ignore_patterns] << pattern
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

puts "=== Security Analysis ===".yellow.bold

Dir.chdir(target_dir) do
  # Check if Brakeman is installed
  unless system("which brakeman > /dev/null 2>&1")
    puts "Brakeman is not installed. Installing...".yellow
    system("gem install brakeman")
  end

  # Enhanced project type detection
  rails_indicators = [
    'config/application.rb',
    'app/controllers/application_controller.rb',
    'config/routes.rb',
    'config/database.yml',
    'bin/rails',
    'bin/rake'
  ]

  rails_present = rails_indicators.all? { |file| File.exist?(file) }

  if rails_present
    puts "Detected Project Type: Rails Project".cyan
    puts "Running Brakeman security analysis...".cyan
    system("brakeman -q --format text") || puts("💔 Brakeman encountered issues.".red)
  else
    puts "Detected Project Type: Ruby Project".cyan
    puts "This doesn't appear to be a Rails project. Skipping Brakeman analysis.".yellow

    # Perform basic security checks for non-Rails projects
    puts "\nPerforming basic security checks:".cyan

    unless system("which bundler-audit > /dev/null 2>&1")
      puts "bundler-audit is not installed. Installing...".yellow
      system("gem install bundler-audit")
    end

    if File.exist?('Gemfile.lock')
      puts "Running bundler-audit for security vulnerabilities...".cyan
      system("bundle audit check --update") || puts("💔 bundler-audit encountered issues.".red)
    else
      puts "This project doesn't have a Gemfile.lock.".yellow
    end

    # Check for hardcoded secrets
    secret_patterns = [
      /password\s*=\s*['"][^'"]+['"]/,
      /api_key\s*=\s*['"][^'"]+['"]/,
      /secret\s*=\s*['"][^'"]+['"]/
    ]

    Dir.glob('**/*.rb').each do |file|
      next if file.start_with?('vendor/') || file.start_with?('node_modules/')

      File.readlines(file).each_with_index do |line, index|
        secret_patterns.each do |pattern|
          if line.match?(pattern)
            puts "  ⚠️  Potential hardcoded secret in #{file}:#{index + 1}".red
          end
        end
      end
    end

    # Check for vulnerable gem versions (example)
    if File.exist?('Gemfile.lock')
      vulnerable_gems = {
        'rails' => Gem::Requirement.new(['< 5.2.4.3']),
        'rack' => Gem::Requirement.new(['< 2.2.3'])
      }

      current_gems = {}
      File.readlines('Gemfile.lock').each do |line|
        if line =~ /^\s{4}(\S+)\s\((.*?)\)/
          gem, version = $1, $2
          current_gems[gem] = Gem::Version.new(version)
        end
      end

      vulnerable_gems.each do |gem, requirement|
        if current_gems[gem] && !requirement.satisfied_by?(current_gems[gem])
          puts "  ⚠️  Potentially vulnerable gem: #{gem} (#{current_gems[gem]})".red
        end
      end
    end
  end
end

puts "===================================".yellow.bold
