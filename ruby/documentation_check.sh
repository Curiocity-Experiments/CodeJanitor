#!/bin/bash

# Usage function
usage() {
  echo "Usage: $0 [options] <path_to_analyze>"
  echo ""
  echo "Options:"
  echo "  -h, --help            Display this help message"
  echo "  -i, --ignore PATTERN  Add an additional ignore pattern (can be used multiple times)"
  exit 1
}

# Default values
IGNORE_PATTERNS=()

# Parse options
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -h|--help) usage ;;
    -i|--ignore)
      shift
      IGNORE_PATTERNS+=("$1")
      ;;
    *)
      TARGET_DIR="$1"
      ;;
  esac
  shift
done

# Check if target directory is provided
if [ -z "$TARGET_DIR" ]; then
  echo "Error: No path provided to analyze." >&2
  usage
fi

if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: Directory '$TARGET_DIR' does not exist." >&2
  exit 1
fi

cd "$TARGET_DIR"

# Function to handle ignore patterns
handle_ignore() {
  local script_name=$1
  shift
  local additional_ignores=("$@")
  local ignore_conditions=""
  for pattern in "${additional_ignores[@]}"; do
    ignore_conditions+=" -not -path './$pattern' "
  done
  echo "$ignore_conditions"
}

echo -e "$(tput setaf 3)=== Documentation and README Analysis ===$(tput sgr0)"

# Detect project type
if [ -f "Gemfile" ]; then
  PROJECT_TYPE="Rails/Ruby Project"
elif ls *.gemspec 1> /dev/null 2>&1; then
  PROJECT_TYPE="Ruby Gem"
else
  PROJECT_TYPE="Unknown Ruby Project"
fi

echo -e "$(tput setaf 6)Detected Project Type: $PROJECT_TYPE$(tput sgr0)"

# Check for README files
readme_files=$(find . -maxdepth 2 -type f \( -iname "README.md" -o -iname "README.rdoc" \))
if [ -z "$readme_files" ]; then
  echo -e "❌ No README file found.".red
else
  echo -e "✅ Found README files:".green
  echo "$readme_files" | awk '{print " - " $0}' | colorize -c green
fi

# Define documentation directory based on project type
if [ "$PROJECT_TYPE" == "Rails/Ruby Project" ] || [ "$PROJECT_TYPE" == "Unknown Ruby Project" ]; then
  doc_dir="./docs"
elif [ "$PROJECT_TYPE" == "Ruby Gem" ]; then
  doc_dir="./doc"
fi

# Check for documentation directory
if [ -d "$doc_dir" ]; then
  echo -e "✅ '$(basename "$doc_dir")' directory exists.".green
  doc_count=$(find "$doc_dir" -type f | wc -l)
