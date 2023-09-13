cmake_minimum_required(VERSION 3.18.2...3.27 FATAL_ERROR)

include(CetExclude)
message(STATUS "CMAKE_CURRENT_SOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}")
file(GLOB testfiles LIST_DIRECTORIES FALSE "*")
message(STATUS "testfiles=${testfiles}")
_cet_exclude_from_list(test_basename_exclude BASENAME_EXCLUDES CMakeLists.txt LICENSE LIST ${testfiles})
message(STATUS "test_basename_exclude=${test_basename_exclude}")
_cet_exclude_from_list(test_glob_exclude BASENAME_EXCLUDES "[L-Z]*" "*.txt" LIST ${testfiles}) 
message(STATUS "test_glob_exclude=${test_glob_exclude}")
#_cet_exclude_from_list(test_glob_exclude BASENAME_EXCLUDES "x/y.txt" LIST ${testfiles})
_cet_exclude_from_list(test_full_exclude EXCLUDES "../cetmodules/CMakeLists.txt" "nonsuch" LIST ${testfiles})
