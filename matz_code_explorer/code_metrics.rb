#!/usr/bin/env ruby
# code_metrics.rb

require 'json'
require 'optparse'
require 'colorize'
require 'parser/current'
require 'ast'


def menu_info
  {
    title: "Code Metrics Analysis",
    description: "Evaluates code quality and complexity."
  }
end

# Handle the '--info' flag
if ARGV.include?('--info')
  info = menu_info
  puts info[:title]
  puts info[:description]
  exit
end


puts "Code Metrics Analysis: Evaluates code quality and complexity.".cyan
puts "This helps identify areas for improvement and maintain code standards.".cyan
puts ""

begin
  require 'rubocop'
  require 'rubocop-performance'
  require 'rubocop-rspec'
  require 'parser/current'
rescue LoadError => e
  missing_gem = e.message.split(' ').last
  puts "Installing missing RuboCop gems: #{missing_gem}...".yellow
  system("gem install #{missing_gem}")
  Gem.clear_paths
  retry
end

options = { ignore_patterns: [] }
OptionParser.new do |opts|
  opts.banner = "Usage: code_metrics.rb [options]"

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

puts "=== Code Metrics and Complexity ===".yellow.bold

unless system('which rubocop > /dev/null 2>&1')
  puts "RuboCop not found. Installing...".yellow
  system('gem install rubocop rubocop-performance rubocop-rspec')
end

Dir.chdir(target_dir) do
  # Run RuboCop with metrics
  puts "Running RuboCop...".cyan
  system('rubocop --format json --out rubocop_metrics.json --only Metrics --force-default-config')

  if File.exist?('rubocop_metrics.json') && !File.zero?('rubocop_metrics.json')
    metrics = JSON.parse(File.read('rubocop_metrics.json'))

    puts "\nRuboCop metrics:".cyan
    puts "Total Files Analyzed: #{metrics['summary']['target_file_count']}".green
    puts "Total Offenses: #{metrics['summary']['offense_count']}".green

    %w[fatal error warning refactor convention].each do |severity|
      count = metrics['summary']["#{severity}_count"]
      color = severity == 'fatal' || severity == 'error' ? :red : :yellow
      puts "  - #{severity.capitalize} Severity: #{count}".send(color)
    end
  else
    puts "Error running RuboCop.".red
  end
end

class CodeMetricsProcessor < AST::Processor
  attr_reader :class_count, :method_count

  def initialize
    @class_count = 0
    @method_count = 0
  end

  def on_class(node)
    @class_count += 1
    super # Visit child nodes
  end

  def on_module(node)
    @class_count += 1
    super # Visit child nodes
  end

  def on_def(node)
    @method_count += 1
    super # Visit child nodes
  end

  def on_defs(node)
    @method_count += 1
    super # Visit child nodes
  end
end

# Function to count classes and methods using parser
def count_definitions(file)
  buffer = Parser::Source::Buffer.new(file)
  buffer.source = File.read(file)
  parser = Parser::CurrentRuby.new
  ast = parser.parse(buffer)

  processor = CodeMetricsProcessor.new
  processor.process(ast) if ast

  return processor.class_count, processor.method_count
rescue Parser::SyntaxError => e
  puts "Syntax error in file #{file}: #{e.message}".red
  return 0, 0
end

total_classes = 0
total_methods = 0

Dir.glob('**/*.rb').each do |file|
  next if file.start_with?('vendor/') || file.start_with?('node_modules/')

  classes, methods = count_definitions(file)
  total_classes += classes
  total_methods += methods
end

puts "\nCode Statistics:".cyan
puts "Total Classes: #{total_classes}".green
puts "Total Methods: #{total_methods}".green

puts "===================================".yellow.bold
