# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Contains the js_library which can be used to expose any library package.
"""

load(
    "@build_bazel_rules_nodejs//:providers.bzl",
    "DeclarationInfo",
    "LinkablePackageInfo",
    "NpmPackageInfo",
    "js_module_info",
    "js_named_module_info",
)

_AMD_NAMES_DOC = """Mapping from require module names to global variables.
This allows devmode JS sources to load unnamed UMD bundles from third-party libraries."""

AmdNamesInfo = provider(
    doc = "provide access to the amd_names attribute of js_library",
    fields = {"names": _AMD_NAMES_DOC},
)

def write_amd_names_shim(actions, amd_names_shim, targets):
    """Shim AMD names for UMD bundles that were shipped anonymous.
    These are collected from our bootstrap deps (the only place global scripts should appear)
    Args:
      actions: skylark rule execution context.actions
      amd_names_shim: File where the shim is written
      targets: dependencies to be scanned for AmdNamesInfo providers
    """

    amd_names_shim_content = """// GENERATED by js_library.bzl
// Shim these global symbols which were defined by a bootstrap script
// so that they can be loaded with named require statements.
"""
    for t in targets:
        if AmdNamesInfo in t:
            for n in t[AmdNamesInfo].names.items():
                amd_names_shim_content += "define(\"%s\", function() { return %s });\n" % n
    actions.write(amd_names_shim, amd_names_shim_content)

def _js_library_impl(ctx):
    direct_sources = depset(ctx.files.srcs)
    sources_depsets = [direct_sources]

    # We cannot always expose the NpmPackageInfo as the linker
    # only allow us to reference node modules from a single workspace at a time.
    # Here we are automatically decide if we should or not including that provider
    # by running through the sources and check if we have a src coming from an external
    # workspace which indicates we should include the provider.
    include_npm_package_info = False
    for src in ctx.files.srcs:
        if src.is_source and src.path.startswith("external/"):
            include_npm_package_info = True
            break

    declarations = depset([
        f
        for f in ctx.files.srcs
        if (
               f.path.endswith(".d.ts") or
               # package.json may be required to resolve "typings" key
               f.path.endswith("/package.json")
           ) and
           # exclude eg. external/npm/node_modules/protobufjs/node_modules/@types/node/index.d.ts
           # these would be duplicates of the typings provided directly in another dependency.
           # also exclude all /node_modules/typescript/lib/lib.*.d.ts files as these are determined by
           # the tsconfig "lib" attribute
           len(f.path.split("/node_modules/")) < 3 and f.path.find("/node_modules/typescript/lib/lib.") == -1
    ])

    transitive_declarations_depsets = [declarations]

    for dep in ctx.attr.deps:
        if DeclarationInfo in dep:
            transitive_declarations_depsets.append(dep[DeclarationInfo].transitive_declarations)
        if NpmPackageInfo in dep:
            sources_depsets.append(dep[NpmPackageInfo].sources)

    transitive_declarations = depset(transitive = transitive_declarations_depsets)
    transitive_sources = depset(transitive = sources_depsets)

    providers = [
        DefaultInfo(
            files = direct_sources,
            runfiles = ctx.runfiles(files = ctx.files.srcs),
        ),
        js_module_info(
            sources = direct_sources,
            deps = ctx.attr.deps,
        ),
        js_named_module_info(
            sources = depset(ctx.files.named_module_srcs),
            deps = ctx.attr.deps,
        ),
        AmdNamesInfo(names = ctx.attr.amd_names),
    ]

    if len(transitive_declarations_depsets) > 0:
        providers.append(DeclarationInfo(
            declarations = declarations,
            transitive_declarations = transitive_declarations,
            type_blacklisted_declarations = depset([]),
        ))

    if ctx.attr.package_name:
        path = "/".join([p for p in [ctx.bin_dir.path, ctx.label.workspace_root, ctx.label.package] if p])
        providers.append(LinkablePackageInfo(
            package_name = ctx.attr.package_name,
            path = path,
            files = depset([
                direct_sources,
                declarations,
            ])
        ))

    if include_npm_package_info:
        workspace_name = ctx.label.workspace_name if ctx.label.workspace_name else ctx.workspace_name
        providers.append(NpmPackageInfo(
            direct_sources = direct_sources,
            sources = transitive_sources,
            workspace = workspace_name,
        ))

    return providers

js_library = rule(
    implementation = _js_library_impl,
    attrs = {
        "amd_names": attr.string_dict(
            doc = _AMD_NAMES_DOC,
            default = {},
        ),
        "deps": attr.label_list(
            doc = "Transitive dependencies of the package",
        ),
        "named_module_srcs": attr.label_list(
            doc = "A subset of srcs that are javascript named-UMD or named-AMD for use in rules such as ts_devserver",
            allow_files = True,
        ),
        "package_name": attr.string(
            doc = """Optional package_name that this package may be imported as.""",
        ),
        "srcs": attr.label_list(
            doc = "The list of files that comprise the package",
            allow_files = True,
        ),
    },
    doc = "Defines a js library package",
)
