# Copyright (c) 2026, solvcon team <contact@solvcon.net>
# BSD 3-Clause License, see COPYING

# Use the compiler, sysroot and flags selected for Pilot, rather than a
# different compiler found independently on PATH.
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
include(CheckCXXSourceCompiles)

execute_process(
    COMMAND xcode-select -p
    OUTPUT_VARIABLE SOLVCON_BUNDLE_XCODE_SELECT
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)
execute_process(
    COMMAND xcrun --sdk macosx --show-sdk-path
    OUTPUT_VARIABLE SOLVCON_BUNDLE_SDK_PATH
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)

check_cxx_source_compiles([=[
#include <algorithm>
#include <array>
#include <cstddef>
#include <format>
#include <functional>
#include <mdspan>
#include <memory>

struct Add
{
    static int operator()(int left, int right) { return left + right; }
}; /* end struct Add */

int main()
{
    std::array<std::size_t, 2> shape{2, 3};
    auto storage = std::make_unique_for_overwrite<int[]>(6);
    std::mdspan<int, std::dextents<std::size_t, 2>> view(storage.get(), 2, 3);
    view[0, 0] = Add{}(1, 2);
    auto size = std::ranges::fold_left(shape, std::size_t{1}, std::multiplies<>{});
    return std::format("{} {}", view[0, 0], size).empty();
}
]=] SOLVCON_BUNDLE_CXX23_AVAILABLE)

if(NOT SOLVCON_BUNDLE_CXX23_AVAILABLE)
    message(FATAL_ERROR
        "The selected compiler and C++ standard library cannot build Pilot.\n"
        "Compiler: ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}\n"
        "Path: ${CMAKE_CXX_COMPILER}\n"
        "DEVELOPER_DIR: $ENV{DEVELOPER_DIR}\n"
        "xcode-select: ${SOLVCON_BUNDLE_XCODE_SELECT}\n"
        "SDK: ${SOLVCON_BUNDLE_SDK_PATH}\n"
        "Required: std::format, std::mdspan, std::ranges::fold_left, "
        "std::make_unique_for_overwrite and static operator().\n"
        "Select a newer Xcode toolchain and SDK with DEVELOPER_DIR. "
        "Reference macOS CI uses Xcode 26.6 / AppleClang 21.0.0.\n"
        "Python and Qt dependencies do not supply these compiler features."
    )
endif()

# vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4 tw=79:
