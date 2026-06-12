#!/bin/bash
# -----------------------------------------------------------------------------
# Author: Ryo Nakagami
# Revised: 2026-06-12
# Script: version.sh
# Description:
#   Utility for printing the package version from the repository-level
#   VERSION file. Intended to be sourced by scripts under bin/ to
#   implement '-v|--version' behavior.
#
# Usage:
#   # As a library (recommended):
#   source ./version.sh
#   print_version            # -> "regmonkey-shellutils 0.1.0"
#
# Notes:
#   - Requires Bash.
#   - The VERSION file is resolved relative to this library
#     (../VERSION) unless an explicit path is given.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Function: print_version
#
# Description:
#   Prints 'regmonkey-shellutils <version>' where <version> is the first
#   line of the VERSION file. The VERSION file defaults to the repository
#   root one (resolved relative to this library), but an explicit path
#   can be supplied for testing or alternate layouts.
#
# Globals:
#   None
#
# Arguments:
#   $1 : (optional) Path to the VERSION file. Defaults to '../VERSION'
#        relative to this library file.
#
# Outputs:
#   STDOUT : 'regmonkey-shellutils <version>'
#   STDERR : Error messages when the VERSION file is missing or empty.
#
# Returns:
#   0 : Successfully printed the version.
#   2 : VERSION file is missing or unreadable.
#   3 : VERSION file is empty.
# -----------------------------------------------------------------------------
print_version() {
  local package_name="regmonkey-shellutils"
  local version_file="${1:-}"

  if [[ -z "${version_file}" ]]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    version_file="${lib_dir}/../VERSION"
  fi

  if [[ ! -r "${version_file}" ]]; then
    printf '%s\n' "print_version: cannot read VERSION file: ${version_file}" >&2
    return 2
  fi

  local version=""
  IFS= read -r version < "${version_file}" || true
  # strip surrounding whitespace
  version="${version#"${version%%[![:space:]]*}"}"
  version="${version%"${version##*[![:space:]]}"}"

  if [[ -z "${version}" ]]; then
    printf '%s\n' "print_version: VERSION file is empty: ${version_file}" >&2
    return 3
  fi

  printf '%s %s\n' "${package_name}" "${version}"
  return 0
}
