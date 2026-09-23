# Builds the Pythia 8 driver of the engine on Windows (MSVC, x64 and ARM64).
#
# Pythia is GPL and is not carried here: unpack its source tree yourself and point at it. Pythia has no
# Windows build system of its own, so its sources are compiled here directly into a static library — nothing
# in them is modified, the only thing Windows lacks (<dlfcn.h>) comes from compat/.
#
#   cmake -B build -S . -DPYTHIA8_DIR=C:/src/pythia8318
#   cmake --build build --config Release
#   cmake --install build --prefix "$env:LOCALAPPDATA/TreeLevel MC Engine/Modules/pythia8"
#
# win/backends/pythia/build.ps1 does the three of them.
#
# Copyright (C) 2026 Guglielmo Pasa. GNU General Public License v3 or later (Pythia 8 is GPL).

cmake_minimum_required(VERSION 3.21)
project(treelevel-pythia CXX)

set(PYTHIA8_DIR "" CACHE PATH "Unpacked Pythia 8 source tree — the folder holding include/, src/ and share/")
if(NOT PYTHIA8_DIR OR NOT EXISTS "${PYTHIA8_DIR}/include/Pythia8/Pythia.h")
  message(FATAL_ERROR
    "Pythia 8 not found. Download it from https://pythia.org, unpack it, and configure with\n"
    "  cmake -B build -S . -DPYTHIA8_DIR=<the folder holding include/ and src/>")
endif()

set(DRIVER "${CMAKE_CURRENT_SOURCE_DIR}/../../../Backends/pythia/main.cpp")
if(NOT EXISTS "${DRIVER}")
  message(FATAL_ERROR "the driver ${DRIVER} is missing — build from a full checkout of the engine")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()
# The static runtime, so that the module runs on a machine without the Visual C++ redistributable.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

file(GLOB PYTHIA8_SOURCES CONFIGURE_DEPENDS "${PYTHIA8_DIR}/src/*.cc")
list(LENGTH PYTHIA8_SOURCES PYTHIA8_COUNT)
if(PYTHIA8_COUNT EQUAL 0)
  message(FATAL_ERROR "no source file in ${PYTHIA8_DIR}/src")
endif()
message(STATUS "Pythia 8: ${PYTHIA8_COUNT} source files from ${PYTHIA8_DIR}")

add_library(pythia8 STATIC ${PYTHIA8_SOURCES})
target_include_directories(pythia8 PUBLIC "${PYTHIA8_DIR}/include" "${CMAKE_CURRENT_SOURCE_DIR}/compat")

if(MSVC)
  # /FIiso646.h   the alternative tokens (and, or, not), which MSVC only knows through that header
  # /FIwin_clock.h compat/win_clock.h, for the clock_gettime Basics.h calls
  # /bigobj      a few of Pythia's translation units pass the object-file section limit
  # /utf-8       the sources are UTF-8 and MSVC would otherwise read them in the system code page
  target_compile_options(pythia8 PUBLIC /EHsc /bigobj /utf-8 /FIiso646.h /FIwin_clock.h /W3
                         /wd4244 /wd4267 /wd4305 /wd4838 /wd4996 /wd4018 /wd4146)
  # _USE_MATH_DEFINES  M_E and friends, which MSVC only defines on request
  # fjcore_EXPORTS     the knob FJcore offers on Windows; without it its static members are dllimport
  target_compile_definitions(pythia8 PUBLIC _CRT_SECURE_NO_WARNINGS NOMINMAX WIN32_LEAN_AND_MEAN
                             _USE_MATH_DEFINES fjcore_EXPORTS)
  target_compile_options(pythia8 PRIVATE $<$<CONFIG:Release>:/O2>)
  # One compilation per core: a hundred translation units otherwise take a quarter of an hour.
  target_compile_options(pythia8 PRIVATE /MP)
endif()

add_executable(treelevel-pythia "${DRIVER}")
target_link_libraries(treelevel-pythia PRIVATE pythia8)

install(TARGETS treelevel-pythia RUNTIME DESTINATION .)
# Pythia reads its settings, its particle data, its tunes and its parton densities from share/Pythia8 at every
# run, and looks for them beside xmldoc: the module carries its own copy. htmldoc and pdfdoc are documentation
# and are left out; pdfdata is 50 MB but is what hadron beams need.
set(PYTHIA8_SHARE "${PYTHIA8_DIR}/share/Pythia8")
if(NOT EXISTS "${PYTHIA8_SHARE}/xmldoc")
  set(PYTHIA8_SHARE "${PYTHIA8_DIR}")
endif()
if(EXISTS "${PYTHIA8_SHARE}/xmldoc")
  foreach(folder xmldoc tunes setups pdfdata)
    if(EXISTS "${PYTHIA8_SHARE}/${folder}")
      install(DIRECTORY "${PYTHIA8_SHARE}/${folder}" DESTINATION .)
    endif()
  endforeach()
else()
  message(WARNING "xmldoc not found under ${PYTHIA8_DIR}: the driver will need PYTHIA8DATA")
endif()
install(FILES "${PYTHIA8_DIR}/COPYING" DESTINATION . RENAME COPYING.pythia8 OPTIONAL)

# Pythia's last resort when neither PYTHIA8DATA nor the folder given to its constructor holds Index.xml. The
# driver looks beside itself first, so this only ever helps a build run from the tree it was compiled in.
if(EXISTS "${PYTHIA8_DIR}/share/Pythia8/xmldoc")
  target_compile_definitions(pythia8 PRIVATE XMLDIR="${PYTHIA8_DIR}/share/Pythia8/xmldoc")
else()
  target_compile_definitions(pythia8 PRIVATE XMLDIR="${PYTHIA8_DIR}/xmldoc")
endif()
