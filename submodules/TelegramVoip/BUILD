load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "OngoingCallVersionPolicy",
    module_name = "OngoingCallVersionPolicy",
    srcs = glob([
        "VersionPolicy/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "OngoingCallVersionPolicyTestsLib",
    testonly = True,
    srcs = glob([
        "VersionPolicy/Tests/**/*.swift",
    ]),
    deps = [
        ":OngoingCallVersionPolicy",
    ],
)

ios_test_runner(
    name = "OngoingCallVersionPolicyTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "OngoingCallVersionPolicyTests",
    minimum_os_version = "15.0",
    runner = ":OngoingCallVersionPolicyTestRunner",
    deps = [
        ":OngoingCallVersionPolicyTestsLib",
    ],
)

swift_library(
    name = "TelegramVoip",
    module_name = "TelegramVoip",
    srcs = glob([
        "Sources/**/*.swift",
    ], exclude = [
        "Sources/macOS/**/*",
    ]),
    copts = [
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/TgVoipWebrtc:TgVoipWebrtc",
        "//submodules/FFMpegBinding",
        "//submodules/ManagedFile",
        "//submodules/AppBundle",
        ":OngoingCallVersionPolicy",
    ],
    visibility = [
        "//visibility:public",
    ],
)
