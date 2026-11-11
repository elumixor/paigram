load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

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
