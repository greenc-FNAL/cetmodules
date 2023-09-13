#[================================================================[.rst:
CetParseArgs
============
#]================================================================]
include_guard()

cmake_minimum_required(VERSION 3.18.2...3.27 FATAL_ERROR)
include(Compatibility)
function(cet_parse_args PREFIX ARGS FLAGS)
  warn_deprecated("cet_parse_args()" NEW "cmake_parse_arguments()")
  cmake_parse_arguments(PARSE_ARGV 3 "${PREFIX}" "${FLAGS}" "" "${ARGS}")
  get_property(vars DIRECTORY PROPERTY VARIABLES)
  list(FILTER vars INCLUDE REGEX "^${PREFIX}_")
  foreach (var IN LISTS vars)
    set(${var} "${${var}}" PARENT_SCOPE)
  endforeach()
  if (${PREFIX}_UNPARSED_ARGUMENTS)
    set(${PREFIX}_DEFAULT_ARGS "${PREFIX}_UNPARSED_ARGUMENTS}" PARENT_SCOPE)
    unset(${PREFIX}_UNPARSED_ARGUMENTS PARENT_SCOPE)
  endif()
endfunction()

