load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "LocalAudioTranscription",
    module_name = "LocalAudioTranscription",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "LocalAudioTranscriptionTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":LocalAudioTranscription",
    ],
)

ios_test_runner(
    name = "LocalAudioTranscriptionTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "LocalAudioTranscriptionTests",
    minimum_os_version = "13.0",
    runner = ":LocalAudioTranscriptionTestRunner",
    deps = [
        ":LocalAudioTranscriptionTestsLib",
    ],
)
