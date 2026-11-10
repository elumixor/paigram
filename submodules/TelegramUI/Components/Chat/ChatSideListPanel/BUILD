load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ChatSideListPanel",
    module_name = "ChatSideListPanel",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramPresentationData",
        "//submodules/AccountContext",
        "//submodules/SolidRoundedButtonNode",
    ],
    visibility = [
        "//visibility:public",
    ],
)
