include_guard(DIRECTORY)

cmake_policy(PUSH)
cmake_minimum_required(VERSION 3.18.2 FATAL_ERROR)

include(CetPackagePath)
include(CetRegexEscape)

function(cet_installed_path OUT_VAR)
  cmake_parse_arguments(PARSE_ARGV 1 CIP "" "RELATIVE;RELATIVE_VAR" "")
  list(POP_FRONT CIP_UNPARSED_ARGUMENTS PATH)
  if (CIP_RELATIVE AND CIP_RELATIVE_VAR)
    message(FATAL_ERROR "RELATIVE and RELATIVE_VAR are mutually exclusive")
  elseif (NOT (CIP_RELATIVE OR CIP_RELATIVE_VAR))
    message(FATAL_ERROR "one of RELATIVE or RELATIVE_VAR are required")
  endif()
  cet_package_path(pkg_path PATH "${PATH}")
  if (NOT pkg_path)
    set(pkg_path "${PATH}")
  endif()
  if (CIP_RELATIVE_VAR)
    if (NOT ${CIP_RELATIVE_VAR} IN_LIST CETMODULES_VARS_PROJECT_${PROJECT_NAME})
      message(FATAL_ERROR "RELATIVE_VAR ${CIP_RELATIVE_VAR} is not a project variable for project ${PROJECT_NAME}")
    endif()
    cet_regex_escape("${${PROJECT_NAME}_EXEC_PREFIX}" VAR e_exec_prefix)
    string(REGEX REPLACE "^(${e_exec_prefix}/+)?(.+)$" "\\2" relvar "${${PROJECT_NAME}_${CIP_RELATIVE_VAR}}")
    cet_regex_escape("${relvar}" VAR e_relvar)
    string(REGEX REPLACE "^(${e_relvar}/+)?(.+)$" "\\2" result "${pkg_path}")
  else()
    cet_regex_escape("${CIP_RELATIVE}" VAR e_rel)
    string(REGEX REPLACE "^(${e_relvar}/+)?(.+)$" "\\2" result "${pkg_path}")
  endif()
  if (result)
    set(${OUT_VAR} "${result}" PARENT_SCOPE)
  else()
    set(${OUT_VAR} "${PATH}" PARENT_SCOPE)
  endif()
endfunction()

cmake_policy(POP)
