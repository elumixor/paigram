load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "PaiPasskeyCore",
    module_name = "PaiPasskeyCore",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "PaiPasskeyCoreTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":PaiPasskeyCore",
    ],
)

ios_test_runner(
    name = "PaiPasskeyCoreTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "PaiPasskeyCoreTests",
    minimum_os_version = "13.0",
    runner = ":PaiPasskeyCoreTestRunner",
    deps = [
        ":PaiPasskeyCoreTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
