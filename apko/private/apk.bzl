"Repository rules for importing remote apk packages"

load("@bazel_skylib//lib:versions.bzl", "versions")
load(":util.bzl", "util")

APK_IMPORT_TMPL = """\
# Generated by apk_import. DO NOT EDIT
filegroup(
    name = "all",
    srcs = glob(
        ["**/*.tar.gz", "**/*.apk"],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"]
)
"""

def _auth(rctx, url):
    if "HTTP_AUTH" not in rctx.os.environ:
        return {}
    http_auth = rctx.os.environ["HTTP_AUTH"]

    parts = http_auth.split(":", 3)
    if len(parts) != 4:
        fail("malformed HTTP_AUTH environment variable wanted basic:REALM:USER:PASSWORD, but got {} parts", len(parts))

    if parts[0].lower() != "basic":
        fail("malformed HTTP_AUTH environment variable wanted basic:REALM:USER:PASSWORD, but got {} for first part", parts[0])

    if not url.startswith("https://{}".format(parts[1])):
        return {}

    return {
        url: {
            "type": "basic",
            "login": parts[2],
            "password": parts[3],
        },
    }

def _range(url, range):
    return "{}#_apk_range_{}".format(url, range.replace("=", "_"))

def _check_initial_setup(rctx):
    output = rctx.path(".rangecheck/output")
    _download(
        rctx,
        url = rctx.attr.url,
        rng = "bytes=0-0",
        output = output,
    )
    r = rctx.execute(["wc", "-c", output])

    if r.return_code != 0:
        fail("initial setup check failed ({}) stderr: {}\n stdout: {}".format(r.statuscode, r.stderr, r.stdout))

    bytes = r.stdout.lstrip(" ").split(" ")

    if bytes[0] != "1":
        fail("""

‼️ We encountered an issue with your current configuration that prevents partial package fetching during downloads.

This may indicate either a misconfiguration or that the initial setup hasn't been performed correctly.
To resolve this issue and enable partial package fetching, please follow the step-by-step instructions in our documentation.

📚 Documentation: https://github.com/chainguard-dev/rules_apko/blob/main/docs/initial-setup.md

""".format(bytes[0]))

def _download(rctx, url, rng, **kwargs):
    if versions.is_at_least("7.1.0", native.bazel_version):
        return rctx.download(
            url = [url],
            headers = {"Range": [rng]},
            auth = _auth(rctx, url),
            **kwargs
        )
    else:
        return rctx.download(
            url = [_range(url, rng)],
            auth = _auth(rctx, url),
            **kwargs
        )

def _apk_import_impl(rctx):
    repo = util.repo_url(rctx.attr.url, rctx.attr.architecture)
    repo_escaped = util.url_escape(repo)

    output = "{}/{}/{}-{}".format(repo_escaped, rctx.attr.architecture, rctx.attr.package_name, rctx.attr.version)

    control_sha256 = util.normalize_sri(rctx, rctx.attr.control_checksum)
    data_sha256 = util.normalize_sri(rctx, rctx.attr.data_checksum)

    sig_output = "{}/{}.sig.tar.gz".format(output, control_sha256)
    control_output = "{}/{}.ctl.tar.gz".format(output, control_sha256)
    data_output = "{}/{}.dat.tar.gz".format(output, data_sha256)
    apk_output = "{}/{}/{}-{}.apk".format(repo_escaped, rctx.attr.architecture, rctx.attr.package_name, rctx.attr.version)

    _download(
        rctx,
        url = rctx.attr.url,
        rng = rctx.attr.signature_range,
        output = sig_output,
        # TODO: signatures does not have stable checksums. find a way to fail gracefully.
        # integrity = rctx.attr.signature_checksum,
    )
    _download(
        rctx,
        url = rctx.attr.url,
        rng = rctx.attr.control_range,
        output = control_output,
        integrity = rctx.attr.control_checksum,
    )
    _download(
        rctx,
        url = rctx.attr.url,
        rng = rctx.attr.data_range,
        output = data_output,
        integrity = rctx.attr.data_checksum,
    )

    util.concatenate_gzip_segments(
        rctx,
        output = apk_output,
        signature = sig_output,
        control = control_output,
        data = data_output,
    )
    rctx.file("BUILD.bazel", APK_IMPORT_TMPL)

apk_import = repository_rule(
    implementation = _apk_import_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "architecture": attr.string(mandatory = True),
        "url": attr.string(mandatory = True),
        "signature_range": attr.string(mandatory = True),
        "signature_checksum": attr.string(mandatory = True),
        "control_range": attr.string(mandatory = True),
        "control_checksum": attr.string(mandatory = True),
        "data_range": attr.string(mandatory = True),
        "data_checksum": attr.string(mandatory = True),
    },
)

APK_REPOSITORY_TMPL = """\
# Generated by apk_repository. DO NOT EDIT
filegroup(
    name = "index",
    srcs = glob(["**/APKINDEX/*.tar.gz"]),
    visibility = ["//visibility:public"]
)
"""

def _apk_repository_impl(rctx):
    repo = util.repo_url(rctx.attr.url, rctx.attr.architecture)
    repo_escaped = util.url_escape(repo)
    _check_initial_setup(rctx)
    rctx.download(
        url = [rctx.attr.url],
        auth = _auth(rctx, rctx.attr.url),
        output = "{}/{}/APKINDEX/latest.tar.gz".format(repo_escaped, rctx.attr.architecture),
    )
    rctx.file("BUILD.bazel", APK_REPOSITORY_TMPL)

apk_repository = repository_rule(
    implementation = _apk_repository_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "architecture": attr.string(mandatory = True),
    },
)

APK_KEYRING_TMPL = """\
# Generated by apk_import. DO NOT EDIT
filegroup(
    name = "keyring",
    srcs = ["{public_key}"],
    visibility = ["//visibility:public"]
)
"""

def _cachePathFromURL(url):
    """
    Translates URL to a name of local directory that can be used to represent prefetched content of the URL.

    Mimicks https://github.com/chainguard-dev/go-apk/blob/7b08e8f3b0fcaa0f0a44757aedf23f6778cd8e4f/pkg/apk/cache.go#L326C6-L326C22
    Is interprets URL as following path: {repo}/{arch}/{file} [but also used for keyring files that don't obey {arch} part].

    Examples:
      https://packages.wolfi.dev/os/wolfi-signing.rsa.pub              -> https%3A%2F%2Fpackages.wolfi.dev%2F/os/wolfi-signing.rsa.pub
      https://packages.wolfi.dev/os/aarch64/sqlite-libs-3.44.0-r0.apk  -> https%3A%2F%2Fpackages.wolfi.dev%2Fos/arch64/sqlite-libs-3.44.0-r0.apk
    """
    url_split = url.rsplit("/", 2)
    repo = url_split[0]
    if len(repo.split("/")) <= 3:
        # Seems the Apko adds additional "/" if the URL is short.
        repo += "/"
    repo_escaped = util.url_escape(repo)
    return "{}/{}/{}".format(repo_escaped, url_split[1], url_split[2])

def _apk_keyring_impl(rctx):
    public_key = _cachePathFromURL(rctx.attr.url)
    rctx.download(url = [rctx.attr.url], output = public_key, auth = _auth(rctx, rctx.attr.url))
    rctx.file("BUILD.bazel", APK_KEYRING_TMPL.format(public_key = public_key))

apk_keyring = repository_rule(
    implementation = _apk_keyring_impl,
    attrs = {
        "url": attr.string(mandatory = True),
    },
)

def _apk_filegroup_impl(ctx):
    lockfile = depset([ctx.file.lockfile])
    apks = depset(ctx.files.apks)
    indexes = depset(ctx.files.indexes)
    keyrings = depset(ctx.files.keyrings)
    return [
        DefaultInfo(files = depset(transitive = [lockfile, apks, indexes, keyrings])),
        OutputGroupInfo(
            lockfile = lockfile,
            apks = apks,
            indexes = indexes,
            keyrings = keyrings,
        ),
    ]

apk_filegroup = rule(
    implementation = _apk_filegroup_impl,
    attrs = {
        "lockfile": attr.label(doc = "Label to the `apko.lock.json` file.", allow_single_file = True, mandatory = True),
        "keyrings": attr.label_list(doc = "Labels of the keyring (public key) files.", allow_files = True, mandatory = True),
        "apks": attr.label_list(doc = "Labels of the package (apk) files.", allow_files = True, mandatory = True),
        "indexes": attr.label_list(doc = "Labels of the APKINDEX files.", allow_files = True, mandatory = True),
    },
)
