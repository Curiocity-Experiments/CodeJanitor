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

echo -e "$(tput setaf 3)=== Code Metrics and Complexity ===$(tput sgr0)"

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

# Ensure rubocop is installed
if ! command -v rubocop &> /dev/null; then
    echo "Rubocop not found. Installing..." | tee -a /dev/stderr
    gem install rubocop
fi

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq not found. Installing..." | tee -a /dev/stderr
    # Installation command based on OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo apt-get update && sudo apt-get install -y jq
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        brew install jq
    else
        echo "Please install jq manually." | tee -a /dev/stderr
        exit 1
    fi
fi

# Run RuboCop with metrics
rubocop --format json > rubocop_metrics.json

if [ $? -ne 0 ] && [ ! -s rubocop_metrics.json ]; then
  echo "Error running RuboCop." | tee -a /dev/stderr
  exit 1
fi

echo "RuboCop metrics saved to rubocop_metrics.json".cyan

# Parse RuboCop metrics
total_offenses=$(jq '.summary.offense_count' rubocop_metrics.json)
total_files=$(jq '.summary.file_count' rubocop_metrics.json)

# Calculate total classes
total_classes=$(find . -name '*.rb' -not \( -path "./scripts/*" -o -path "./vendor/*" -o -path "./node_modules/*" \) 2>/dev/null | xargs grep -c '^\s*class ' 2>/dev/null | awk '{sum += $1} END {print sum}')
total_classes=${total_classes:-0}

# Calculate total methods
total_methods=$(find . -name '*.rb' -not \( -path "./scripts/*" -o -path "./vendor/*" -o -path "./node_modules/*" \) 2>/dev/null | xargs grep -c '^\s*def ' 2>/dev/null | awk '{sum += $1} END {print sum}')
total_methods=${total_methods:-0}

# Summarize RuboCop offenses
if [ "$total_offenses" -gt 0 ]; then
  high_severity=$(jq '.files[].offenses[] | select(.severity == "high")' rubocop_metrics.json | wc -l)
  medium_severity=$(jq '.files[].offenses[] | select(.severity == "medium")' rubocop_metrics.json | wc -l)
  low_severity=$(jq '.files[].offenses[] | select(.severity == "low")' rubocop_metrics.json | wc -l)
else
  high_severity=0
  medium_severity=0
  low_severity=0
fi

# Display metrics
echo -e "Total Files Analyzed: $(tput setaf 6)$total_files$(tput sgr0)"
echo -e "Total Offenses: $(tput setaf 6)$total_offenses$(tput sgr0)"
echo -e "  - High Severity: $(tput setaf 1)$high_severity$(tput sgr0)"
echo -e "  - Medium Severity: $(tput setaf 3)$medium_severity$(tput sgr0)"
echo -e "  - Low Severity: $(tput setaf 2)$low_severity$(tput sgr0)"
echo -e "Total Classes: $(tput setaf 6)$total_classes$(tput sgr0)"
echo -e "Total Methods: $(tput setaf 6)$total_methods$(tput sgr0)"

echo -e "$(tput setaf 3)==================================$(tput sgr0)"
