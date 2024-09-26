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

echo -e "$(tput setaf 3)=== Key Files Identification ===$(tput sgr0)"

# Detect project type
if [ -f "Gemfile" ]; then
  PROJECT_TYPE="Rails/Ruby Project"
elif ls *.gemspec 1> /dev/null 2>&1; then
  PROJECT_TYPE="Ruby Gem"
else
  PROJECT_TYPE="Unknown Ruby Project"
fi

echo -e "$(tput setaf 6)Detected Project Type: $PROJECT_TYPE$(tput sgr0)"

# Define key files based on project type
if [ "$PROJECT_TYPE" == "Rails/Ruby Project" ]; then
  key_files=(
    "Gemfile"
    "Gemfile.lock"
    "Rakefile"
    "config.ru"
    "config/application.rb"
    "config/environment.rb"
    "config/routes.rb"
    "config/database.yml"
    "app/controllers/application_controller.rb"
    "bin/rails"
    "bin/rake"
    "README.md"
  )
elif [ "$PROJECT_TYPE" == "Ruby Gem" ]; then
  gemspec_files=($(ls *.gemspec 2>/dev/null))
  key_files=(
    "Gemfile"
    "${gemspec_files[@]}"
    "lib/your_gem_name.rb"  # Replace with actual gem name if possible
    "README.md"
    "LICENSE.txt"
    "Rakefile"
    "spec/spec_helper.rb"
  )
else
  # Define key files for unknown Ruby projects
  key_files=(
    "Gemfile"
    "Rakefile"
    "README.md"
    "LICENSE.txt"
    "lib/"
    "spec/"
  )
fi

# Check each key file
for file in "${key_files[@]}"; do
  # Handle wildcard patterns and directories
  if [[ "$file" == *"*"* ]]; then
    matches=($(ls $file 2>/dev/null))
    if [ ${#matches[@]} -gt 0 ]; then
      for match in "${matches[@]}"; do
        echo -e "✅ Found: $(tput setaf 2)$match$(tput sgr0)"
      done
    else
      echo -e "❌ Missing: $(tput setaf 1)$file$(tput sgr0)"
    fi
  elif [[ "$file" == */ ]]; then
    # Check for directories
    if [ -d "$file" ]; then
      echo -e "✅ Found Directory: $(tput setaf 2)$file$(tput sgr0)"
    else
      echo -e "❌ Missing Directory: $(tput setaf 1)$file$(tput sgr0)"
    fi
  else
    if [ -e "$file" ]; then
      echo -e "✅ Found: $(tput setaf 2)$file$(tput sgr0)"
    else
      echo -e "❌ Missing: $(tput setaf 1)$file$(tput sgr0)"
    fi
  fi
done

echo -e "$(tput setaf 3)=================================$(tput sgr0)"
