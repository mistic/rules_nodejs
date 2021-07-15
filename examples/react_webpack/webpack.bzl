_WEBPACK_ATTRS = dict(NODE_CONTEXT_ATTRS, **{
    "args": attr.string_list(
        default = [],
    ),
    "config_file": attr.label(
        allow_single_file = True,
    ),
    "deps": attr.label_list(
        aspects = [module_mappings_aspect, node_modules_aspect],
    ),
    "entry_point": attr.label(
        allow_single_file = True,
    ),
    "entry_points": attr.label_keyed_string_dict(
        allow_files = True,
    ),
    "link_workspace_root": attr.bool(
    ),
    "output_dir": attr.bool(
    ),
    "_webpack_worker_plugin": attr.label(
        allow_single_file = True,
        default = ":webpack_worker_plugin.js",
    ),
    "webpack_bin": attr.label(
        executable = True,
        cfg = "host",
        default = (
            # BEGIN-INTERNAL
            "@npm" +
            # END-INTERNAL
            "//webpack-cli/bin:webpack-cli"
        ),
    ),
    "webpack_worker_bin": attr.label(
        executable = True,
        cfg = "host",
        default = "//packages/webpack/bin:webpack-worker",
    ),
    "silent": attr.bool(
    ),
    "srcs": attr.label_list(
        # Don't try to constrain the filenames, could be json, svg, whatever
        allow_files = True,
    ),
    "supports_workers": attr.bool(
        default = False,
    ),
})

def _webpack_bundle(ctx):
    "Generate a rollup config file and run rollup"

    # rollup_bundle supports deps with JS providers. For each dep,
    # JSEcmaScriptModuleInfo is used if found, then JSModuleInfo and finally
    # the DefaultInfo files are used if the former providers are not found.
    deps_depsets = []
    for dep in ctx.attr.deps:
        if JSEcmaScriptModuleInfo in dep:
            deps_depsets.append(dep[JSEcmaScriptModuleInfo].sources)

        if JSModuleInfo in dep:
            deps_depsets.append(dep[JSModuleInfo].sources)
        elif hasattr(dep, "files"):
            deps_depsets.append(dep.files)

        # Also include files from npm deps as inputs.
        # These deps are identified by the ExternalNpmPackageInfo provider.
        if ExternalNpmPackageInfo in dep:
            deps_depsets.append(dep[ExternalNpmPackageInfo].sources)
    deps_inputs = depset(transitive = deps_depsets).to_list()

    inputs = _filter_js(ctx.files.entry_point) + _filter_js(ctx.files.entry_points) + ctx.files.srcs + deps_inputs
    outputs = [getattr(ctx.outputs, o) for o in dir(ctx.outputs)]

    # See CLI documentation at https://rollupjs.org/guide/en/#command-line-reference
    args = ctx.actions.args()

    if ctx.attr.supports_workers:
        # Set to use a multiline param-file for worker mode
        args.use_param_file("@%s", use_always = True)
        args.set_param_file_format("multiline")

    # Add user specified arguments *before* rule supplied arguments
    args.add_all(ctx.attr.args)

    # List entry point argument first to save some argv space
    # Rollup doc says
    # When provided as the first options, it is equivalent to not prefix them with --input
    entry_points = _desugar_entry_points(ctx.label.name, ctx.attr.entry_point, ctx.attr.entry_points, inputs).items()

    # If user requests an output_dir, then use output.dir rather than output.file
    if ctx.attr.output_dir:
        outputs.append(ctx.actions.declare_directory(ctx.label.name))
        for entry_point in entry_points:
            args.add_joined([entry_point[1], entry_point[0]], join_with = "=")
        args.add_all(["--output.dir", outputs[0].path])
    else:
        args.add(entry_points[0][0])
        args.add_all(["--output.file", outputs[0].path])

    args.add_all(["--format", ctx.attr.format])

    if ctx.attr.silent:
        # Run the rollup binary with the --silent flag
        args.add("--silent")

    stamp = ctx.attr.node_context_data[NodeContextInfo].stamp

    config = ctx.actions.declare_file("_%s.rollup_config.js" % ctx.label.name)
    ctx.actions.expand_template(
        template = ctx.file.config_file,
        output = config,
        substitutions = {
            "bazel_info_file": "\"%s\"" % ctx.info_file.path if stamp else "undefined",
            "bazel_version_file": "\"%s\"" % ctx.version_file.path if stamp else "undefined",
        },
    )

    args.add_all(["--config", config.path])
    inputs.append(config)

    if stamp:
        inputs.append(ctx.info_file)
        inputs.append(ctx.version_file)

    # Prevent rollup's module resolver from hopping outside Bazel's sandbox
    # When set to false, symbolic links are followed when resolving a file.
    # When set to true, instead of being followed, symbolic links are treated as if the file is
    # where the link is.
    args.add("--preserveSymlinks")

    if (ctx.attr.sourcemap and ctx.attr.sourcemap != "false"):
        args.add_all(["--sourcemap", ctx.attr.sourcemap])

    executable = "rollup_bin"
    execution_requirements = {}

    if ctx.attr.supports_workers:
        executable = "rollup_worker_bin"
        execution_requirements["supports-workers"] = str(int(ctx.attr.supports_workers))

    run_node(
        ctx,
        progress_message = "Bundling JavaScript %s [rollup]" % outputs[0].short_path,
        executable = executable,
        inputs = inputs,
        outputs = outputs,
        arguments = [args],
        mnemonic = "Rollup",
        execution_requirements = execution_requirements,
        env = {"COMPILATION_MODE": ctx.var["COMPILATION_MODE"]},
        link_workspace_root = ctx.attr.link_workspace_root,
    )

    outputs_depset = depset(outputs)

    return [
        DefaultInfo(files = outputs_depset),
        JSModuleInfo(
            direct_sources = outputs_depset,
            sources = outputs_depset,
        ),
    ]

webpack_bundle = rule(
    implementation = _webpack_bundle,
    attrs = dict(_WEBPACK_ATTRS),
    outputs = _webpack_outs,
)