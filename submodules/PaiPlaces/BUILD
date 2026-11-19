load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "PaiPlaces",
    module_name = "PaiPlaces",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
    ],
    deps = [
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "PaiPlacesTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":PaiPlaces",
    ],
)

ios_test_runner(
    name = "PaiPlacesTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "PaiPlacesTests",
    minimum_os_version = "15.0",
    runner = ":PaiPlacesTestRunner",
    deps = [
        ":PaiPlacesTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
