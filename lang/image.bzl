# Copyright 2017 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Helpers for synthesizing foo_image targets matching foo_binary.
"""

load(
    "//container:container.bzl",
    _container = "container",
)
load(
    "//container:layer_tools.bzl",
    _get_layers = "get_from_target",
)

TransitiveDeps = provider(
    fields = {
        "depset": "a depset of struct(target=<target>, target_deps=<depset>)",
    },
)

FilterLayer = provider(
  fields = {
    "runfiles": "filtered runfiles that should be installed from this layer",
    "filtered_depset": "a filtered depset of struct(target=<target>, target_deps=<depset>)",
  },
)

def _binary_name(ctx):
  # For //foo/bar/baz:blah this would translate to
  # /app/foo/bar/baz/blah
  return "/".join([
      ctx.attr.directory,
      ctx.attr.binary.label.package,
      ctx.attr.binary.label.name,
  ])

def _runfiles_dir(ctx):
  # For @foo//bar/baz:blah this would translate to
  # /app/bar/baz/blah.runfiles
  return _binary_name(ctx) + ".runfiles"

# The directory relative to which all ".short_path" paths are relative.
def _reference_dir(ctx):
  # For @foo//bar/baz:blah this would translate to
  # /app/bar/baz/blah.runfiles/foo
  return "/".join([_runfiles_dir(ctx), ctx.workspace_name])

# The special "external" directory which is an alternate way of accessing
# other repositories.
def _external_dir(ctx):
  # For @foo//bar/baz:blah this would translate to
  # /app/bar/baz/blah.runfiles/foo/external
  return "/".join([_reference_dir(ctx), "external"])

# The final location that this file needs to exist for the foo_binary target to
# properly execute.
def _final_emptyfile_path(ctx, name):
  if not name.startswith('external/'):
    # Names that don't start with external are relative to our own workspace.
    return _reference_dir(ctx) + "/" + name

  # References to workspace-external dependencies, which are identifiable
  # because their path begins with external/, are inconsistent with the
  # form of their File counterparts, whose ".short_form" is relative to
  #    .../foo.runfiles/workspace-name/  (aka _reference_dir(ctx))
  # whereas we see:
  #    external/foreign-workspace/...
  # so we "fix" the empty files' paths by removing "external/" and basing them
  # directly on the runfiles path.
  return "/".join([_runfiles_dir(ctx), name[len("external/"):]])

# The final location that this file needs to exist for the foo_binary target to
# properly execute.
def _final_file_path(ctx, f):
  return "/".join([_reference_dir(ctx), f.short_path])

# The foo_binary independent location in which we store a particular dependency's
# file such that it can be shared.
def _layer_emptyfile_path(ctx, name):
  if not name.startswith('external/'):
    # Names that don't start with external are relative to our own workspace.
    return "/".join([ctx.attr.directory, ctx.workspace_name, name])

  # References to workspace-external dependencies, which are identifiable
  # because their path begins with external/, are inconsistent with the
  # form of their File counterparts, whose ".short_form" is relative to
  #    .../foo.runfiles/workspace-name/  (aka _reference_dir(ctx))
  # whereas we see:
  #    external/foreign-workspace/...
  # so we "fix" the empty files' paths by removing "external/" and basing them
  # directly on the runfiles path.
  return "/".join([ctx.attr.directory, name[len("external/"):]])

# The foo_binary independent location in which we store a particular dependency's
# file such that it can be shared.
def layer_file_path(ctx, f):
  return "/".join([ctx.attr.directory, ctx.workspace_name, f.short_path])

def _default_runfiles(dep):
    if FilterLayer in dep:
      return dep[FilterLayer].runfiles.files
    else:
      return dep.default_runfiles.files

def _default_emptyfiles(dep):
    if FilterLayer in dep:
      return dep[FilterLayer].runfiles.empty_filenames
    else:
      return dep.default_runfiles.empty_filenames

def app_layer_impl(ctx, runfiles=None, emptyfiles=None):
  """Appends a layer for a single dependency's runfiles."""

  runfiles = runfiles or _default_runfiles
  emptyfiles = emptyfiles or _default_emptyfiles

  parent_parts = _get_layers(ctx, ctx.attr.base, ctx.files.base)
  filepath = _final_file_path if ctx.attr.binary else layer_file_path
  emptyfilepath = _final_emptyfile_path if ctx.attr.binary else _layer_emptyfile_path
  dep = ctx.attr.dep or ctx.attr.binary
  top_layer = ctx.attr.binary and not ctx.attr.dep

  # Compute the set of runfiles that have been made available
  # in our base image, tracking absolute paths.
  available = {}
  available.update({
    f: None
    for f in parent_parts.get("transitive_files", depset())
  })

  file_map = {}
  file_map.update({
    filepath(ctx, f): f
    for f in runfiles(dep)
    # It is notable that this assumes that our version of
    # this runfile matches that of the dependency.  It is
    # not clear at this time whether that is an invariant
    # broadly in Bazel.
    if filepath(ctx, f) not in available and layer_file_path(ctx, f) not in available
  })
  empty_files = [
    emptyfilepath(ctx, f)
    for f in emptyfiles(dep)
    if emptyfilepath(ctx, f) not in available and _layer_emptyfile_path(ctx, f) not in available
  ]

  symlinks = {}
  # If the caller provided the binary that will eventually form the
  # app layer, we can already create symlinks to the runfiles path.
  if ctx.attr.binary:
    symlinks.update({
        _final_file_path(ctx, f): layer_file_path(ctx, f)
        for f in runfiles(dep)
        if _final_file_path(ctx, f) not in file_map and _final_file_path(ctx, f) not in available
    })
    symlinks.update({
        _final_emptyfile_path(ctx, f): _layer_emptyfile_path(ctx, f)
        for f in emptyfiles(dep)
        if _final_emptyfile_path(ctx, f) not in empty_files and _final_emptyfile_path(ctx, f) not in available
    })

  entrypoint = None
  if top_layer:
    entrypoint = ctx.attr.entrypoint + [_binary_name(ctx)]
    symlinks.update({
      # Create a symlink from our entrypoint to where it will actually be put
      # under runfiles.
      _binary_name(ctx): _final_file_path(ctx, ctx.executable.binary),
      # Create a directory symlink from <workspace>/external to the runfiles
      # root, since they may be accessed via either path.
      _external_dir(ctx): _runfiles_dir(ctx),
    })

  return _container.image.implementation(
    ctx,
    # We use all absolute paths.
    directory="/", file_map=file_map,
    empty_files=empty_files, symlinks=symlinks,
    # Use entrypoint so we can easily add arguments when the resulting
    # image is `docker run ...`.
    # Per: https://docs.docker.com/engine/reference/builder/#entrypoint
    # we should use the "exec" (list) form of entrypoint.
    entrypoint=entrypoint)

_app_layer = rule(
    attrs = dict(_container.image.attrs.items() + {
        # The binary target for which we are synthesizing an image.
        # If specified, the layer will not be "image agnostic", meaning
        # that the runfiles required by "dep" will be created (or symlinked,
        # if already found in an agnostic path from the base image) under
        # the runfiles dir.
        "binary": attr.label(
            executable = True,
            cfg = "target",
        ),
        # The dependency whose runfiles we're appending.
        # If not specified, then the layer will be treated as the top layer,
        # and all remaining deps of "binary" will be added under runfiles.
        "dep": attr.label(providers = [DefaultInfo]),

        # The base image on which to overlay the dependency layers.
        "base": attr.label(mandatory = True),
        "entrypoint": attr.string_list(default = []),

        # Override the defaults.
        "data_path": attr.string(default = "."),
        "workdir": attr.string(default = "/app"),
        "directory": attr.string(default = "/app"),
        "legacy_run_behavior": attr.bool(default = False),
    }.items()),
    executable = True,
    outputs = _container.image.outputs,
    implementation = app_layer_impl,
)

# Convenience function that instantiates tha _app_layer rule and returns
# the name (useful when chaining layers).
def app_layer(name, **kwargs):
  _app_layer(name=name, **kwargs)
  return name

# Utility function for merging a list of depsets into one depset.
def _merge_depsets(depsets):
  return depset() if len(depsets) == 0 else depset(transitive=depsets)


def _transitive_deps_aspect_impl(target, ctx):
  if FilterLayer in target:
    # If the aspect propagated along the "deps" attr to another filter layer,
    # then take the filtered depset instead of descending further.
    return [TransitiveDeps(depset=target[FilterLayer].filtered_depset)]

  # Collect transitive deps from all children (propagating along "deps" attr).
  target_deps = _merge_depsets([dep[TransitiveDeps].depset for dep in ctx.rule.attr.deps])
  myself = struct(target=target, target_deps=target_deps)
  return [TransitiveDeps(depset=depset([myself], transitive=[target_deps]))]


# Aspect for collecting dependency info.
transitive_deps_aspect = aspect(implementation = _transitive_deps_aspect_impl,
  attr_aspects = ['deps'],
)


def _filter_layer_rule_impl(ctx):
  transitive_deps = ctx.attr.dep[TransitiveDeps].depset

  runfiles = ctx.runfiles()
  filtered_depsets = []
  for transitive_dep in transitive_deps:
    if str(transitive_dep.target.label).startswith(ctx.attr.filter) and str(transitive_dep.target.label) != str(ctx.attr.dep.label):
      runfiles = runfiles.merge(transitive_dep.target.default_runfiles)
      filtered_depsets.append(transitive_dep.target_deps)
  return struct(
    providers = [FilterLayer(runfiles=runfiles, filtered_depset=_merge_depsets(filtered_depsets))],
    # Also forward builtin providers so that the filter_layer() can be used as a normal
    # dependency to native targets (e.g. py_library(deps=[<filter_layer>])).
    py = ctx.attr.dep.py if hasattr(ctx.attr.dep, "py") else None,
  )


# A rule that allows selecting a subset of transitive dependencies, and using
# them as a layer in an image.
filter_layer = rule(
  implementation = _filter_layer_rule_impl,
  attrs = {
    "dep" : attr.label(
      providers=[DefaultInfo],
      aspects=[transitive_deps_aspect],
      mandatory = True,
    ),
    # Include in this layer only transitive dependencies whose label starts with "filter".
    # For example, set filter="@" to include only external dependencies.
    "filter" : attr.string(default=''),
  },
)
