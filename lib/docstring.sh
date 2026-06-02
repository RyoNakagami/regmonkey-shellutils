#!/bin/bash
# -----------------------------------------------------------------------------
# Author: Ryo Nakagami
# Revised: 2026-05-23
# Script: docstring.sh
# Description:
#   Utilities for extracting and displaying the docstring (top-of-file
#   comment block) from a shell script. The docstring is the first
#   contiguous run of '#'-comment lines at the top of the file, with an
#   optional shebang line allowed before it.
#
# Usage:
#   # As a library (recommended):
#   source ./docstring.sh
#   usage_helper "$0"          # Display the current script's docstring
#
# Notes:
#   - Requires Bash and awk.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Function: print_docstring
#
# Description:
#   Extracts and prints the top-level docstring from a given file. The
#   function:
#     - Skips a leading shebang line ('#!...') if present.
#     - Captures the first contiguous block of comment lines ('# ...')
#       at the top of the file.
#     - Stops at the first blank or non-comment line after the block.
#     - Strips the leading '#' and one optional following space from each
#       captured line; further indentation is preserved.
#
# Globals:
#   None
#
# Arguments:
#   $1 : Path to the file from which to extract the docstring.
#
# Outputs:
#   STDOUT : The extracted docstring text (with '#' prefixes removed).
#   STDERR : Error messages when the file is missing or unreadable.
#
# Returns:
#   0 : Successfully printed a docstring.
#   2 : Missing file argument.
#   3 : File is unreadable.
#   4 : No docstring found.
# -----------------------------------------------------------------------------
print_docstring() {
  local file="${1:-}"
  if [[ -z "${file}" ]]; then
    printf '%s\n' "print_docstring: missing file argument" >&2
    return 2
  fi
  if [[ ! -r "${file}" ]]; then
    printf '%s\n' "print_docstring: cannot read file: ${file}" >&2
    return 3
  fi

  # awk handles the whole state machine: skip optional shebang on line 1,
  # collect the first contiguous comment block, strip CRLF, strip '#' and
  # one optional space, stop on the first blank/non-comment line.
  local output
  output=$(awk '
    NR == 1 && /^#!/ { next }
    {
      sub(/\r$/, "")
      if ($0 ~ /^[[:space:]]*#/) {
        seen = 1
        line = $0
        sub(/^[[:space:]]*#/, "", line)
        sub(/^ /, "", line)
        print line
        next
      }
      if (seen) exit 0
    }
  ' "${file}")

  if [[ -z "${output}" ]]; then
    return 4
  fi
  printf '%s\n' "${output}"
  return 0
}

# -----------------------------------------------------------------------------
# Function: usage_helper
#
# Description:
#   Print the docstring/header of a target file using print_docstring().
#   Intended to be sourced by other scripts to implement '-h|--help'
#   behavior. If no argument is provided, defaults to the invoking
#   script ($0).
#
# Globals:
#   None (relies on the externally defined print_docstring function)
#
# Arguments:
#   $1 : (optional) Path to the target file whose docstring should be
#        printed. Defaults to the current script ($0).
#
# Outputs:
#   STDOUT : The docstring text emitted by print_docstring() when found.
#   STDERR : Error message when no docstring/header is found or
#            print_docstring fails.
#
# Returns:
#   0 : Successfully printed the docstring.
#   1 : print_docstring failed (no docstring/header found or other error).
# -----------------------------------------------------------------------------
usage_helper() {
  local target="${1:-$0}"
  if ! print_docstring "${target}"; then
    printf '%s\n' "No docstring/header found in: ${target}" >&2
    return 1
  fi
  return 0
}
