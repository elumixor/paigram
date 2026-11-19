load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

# Foundation-only: the app, the home-screen widget and (copied in by the watch build) the watch app share it.
swift_library(
    name = "PaiGlance",
    module_name = "PaiGlance",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "sources",
    srcs = glob(["Sources/**/*.swift"]),
    visibility = ["//visibility:public"],
)

swift_library(
    name = "PaiGlanceTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":PaiGlance",
    ],
)

ios_test_runner(
    name = "PaiGlanceTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "PaiGlanceTests",
    minimum_os_version = "13.0",
    runner = ":PaiGlanceTestRunner",
    deps = [
        ":PaiGlanceTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
