load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "WalletPagerComponent",
    module_name = "WalletPagerComponent",
    srcs = glob(["Sources/**/*.swift"]),
    copts = [],
    deps = [
        "//submodules/ComponentFlow",
        "//submodules/Components/ViewControllerComponent",
        "//submodules/Display",
    ],
    visibility = ["//visibility:public"],
)
