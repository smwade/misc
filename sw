#!/usr/bin/env python3
"""Publish self-contained static projects under seanwade.com's misc namespace."""

from __future__ import annotations

import argparse
import fnmatch
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import webbrowser
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath


SCRIPT_DIR = Path(__file__).resolve().parent
GLOBAL_CONFIG = json.loads((SCRIPT_DIR / "config.json").read_text())
PROJECT_CONFIG_NAME = ".sw.json"
REGISTRY_PREFIX = f"{GLOBAL_CONFIG['internal_prefix']}/.registry"


class SwError(RuntimeError):
    pass


def run(args: list[str], *, cwd: Path | None = None, capture: bool = False) -> str:
    try:
        result = subprocess.run(
            args,
            cwd=cwd,
            check=True,
            text=True,
            capture_output=capture,
        )
    except FileNotFoundError as exc:
        raise SwError(f"Required command not found: {args[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        raise SwError(detail or f"Command failed: {' '.join(args)}") from exc
    return result.stdout.strip() if capture else ""


def aws(*args: str, capture: bool = False) -> str:
    return run(["aws", *args, "--no-cli-pager"], capture=capture)


def find_project(start: Path | None = None) -> tuple[Path, dict]:
    current = (start or Path.cwd()).resolve()
    for directory in [current, *current.parents]:
        path = directory / PROJECT_CONFIG_NAME
        if path.exists():
            return directory, json.loads(path.read_text())
    raise SwError(f"No {PROJECT_CONFIG_NAME} found. Run `sw init <file-or-output-dir>` first.")


def validate_name(name: str) -> str:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", name):
        raise SwError("Project names must use lowercase letters, numbers, and hyphens.")
    return name


def normalize_public_path(value: str) -> str:
    path = "/" + value.lstrip("/")
    if ".." in PurePosixPath(path).parts or "?" in path or "#" in path:
        raise SwError(f"Invalid public path: {value}")
    return path


def safe_relative(value: str) -> str:
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        raise SwError(f"Path must stay inside the project: {value}")
    return path.as_posix()


def default_name(root: Path) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", root.name.lower()).strip("-")
    return validate_name(value or "project")


def init_project(args: argparse.Namespace) -> tuple[Path, dict]:
    root = Path.cwd().resolve()
    source = Path(args.source or ".")
    source_abs = (root / source).resolve() if not source.is_absolute() else source.resolve()
    if not source_abs.exists():
        raise SwError(f"Source does not exist: {source_abs}")

    name = validate_name(args.name or default_name(root))
    aliases: dict[str, str] = {}

    if source_abs.is_file():
        if source_abs.parent != root:
            raise SwError("For a single-file project, run `sw init` from the file's folder.")
        output = "."
        include = sorted(path.name for path in root.glob("*.html"))
        entry = source_abs.name
        for html_name in include:
            aliases[normalize_public_path(html_name)] = html_name
    else:
        output = os.path.relpath(source_abs, root)
        include = ["**/*"]
        entry = args.entry or "index.html"
        if args.url:
            aliases[normalize_public_path(args.url)] = safe_relative(entry)

    if args.url and source_abs.is_file():
        aliases = {normalize_public_path(args.url): source_abs.name, **{
            path: target for path, target in aliases.items() if target != source_abs.name
        }}

    config = {
        "version": 1,
        "name": name,
        "output": output,
        "entry": safe_relative(entry),
        "include": include,
        "aliases": aliases,
        "install": args.install or "",
        "build": args.build or "",
    }
    config_path = root / PROJECT_CONFIG_NAME
    if config_path.exists() and not args.force:
        raise SwError(f"{config_path} already exists. Use --force to replace it.")
    config_path.write_text(json.dumps(config, indent=2) + "\n")
    print(f"Created {config_path}")
    return root, config


def should_include(relative: str, patterns: list[str]) -> bool:
    return any(
        fnmatch.fnmatch(relative, pattern)
        or (pattern == "**/*" and bool(relative))
        for pattern in patterns
    )


def collect_files(root: Path, config: dict) -> tuple[Path, list[str]]:
    root = root.resolve()
    output = (root / config.get("output", ".")).resolve()
    if not output.is_dir():
        raise SwError(f"Output directory does not exist: {output}")
    try:
        output.relative_to(root)
    except ValueError as exc:
        raise SwError("Output directory must stay inside the project.") from exc

    patterns = config.get("include") or ["**/*"]
    excluded_parts = {".git", ".next", "node_modules", "out", "dist", "build", "__pycache__"}
    files: list[str] = []
    for path in output.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(output).as_posix()
        if path.name in {PROJECT_CONFIG_NAME, ".DS_Store"}:
            continue
        if output == root and any(part in excluded_parts for part in path.relative_to(output).parts):
            continue
        if should_include(relative, patterns):
            files.append(relative)

    if not files:
        raise SwError("No publishable files matched the project's include patterns.")
    return output, sorted(files)


def run_build(root: Path, config: dict) -> None:
    if config.get("install"):
        print(f"Installing: {config['install']}")
        run(["/bin/zsh", "-lc", config["install"]], cwd=root)
    if config.get("build"):
        print(f"Building: {config['build']}")
        run(["/bin/zsh", "-lc", config["build"]], cwd=root)


def kvs_description() -> dict:
    raw = aws(
        "cloudfront-keyvaluestore",
        "describe-key-value-store",
        "--kvs-arn",
        GLOBAL_CONFIG["kvs_arn"],
        "--output",
        "json",
        capture=True,
    )
    return json.loads(raw)


def kvs_get(key: str) -> str | None:
    result = subprocess.run(
        [
            "aws",
            "cloudfront-keyvaluestore",
            "get-key",
            "--kvs-arn",
            GLOBAL_CONFIG["kvs_arn"],
            "--key",
            key,
            "--output",
            "json",
            "--no-cli-pager",
        ],
        text=True,
        capture_output=True,
    )
    if result.returncode:
        if "ResourceNotFoundException" in result.stderr:
            return None
        raise SwError(result.stderr.strip())
    return json.loads(result.stdout)["Value"]


def kvs_put(key: str, value: str, etag: str) -> str:
    raw = aws(
        "cloudfront-keyvaluestore",
        "put-key",
        "--kvs-arn",
        GLOBAL_CONFIG["kvs_arn"],
        "--if-match",
        etag,
        "--key",
        key,
        "--value",
        value,
        "--output",
        "json",
        capture=True,
    )
    return json.loads(raw)["ETag"]


def kvs_delete(key: str, etag: str) -> str:
    raw = aws(
        "cloudfront-keyvaluestore",
        "delete-key",
        "--kvs-arn",
        GLOBAL_CONFIG["kvs_arn"],
        "--if-match",
        etag,
        "--key",
        key,
        "--output",
        "json",
        capture=True,
    )
    return json.loads(raw)["ETag"]


def registry_key(name: str) -> str:
    return f"{REGISTRY_PREFIX}/{name}.json"


def read_registry(name: str) -> dict | None:
    result = subprocess.run(
        ["aws", "s3", "cp", f"s3://{GLOBAL_CONFIG['bucket']}/{registry_key(name)}", "-", "--no-cli-pager"],
        text=True,
        capture_output=True,
    )
    if result.returncode:
        return None
    return json.loads(result.stdout)


def write_registry(data: dict) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
        temp_name = handle.name
    try:
        aws(
            "s3",
            "cp",
            temp_name,
            f"s3://{GLOBAL_CONFIG['bucket']}/{registry_key(data['name'])}",
            "--content-type",
            "application/json",
        )
    finally:
        Path(temp_name).unlink(missing_ok=True)


def internal_target(name: str, relative: str) -> str:
    return f"/{GLOBAL_CONFIG['internal_prefix']}/{name}/{safe_relative(relative)}"


def validate_aliases(config: dict, files: list[str], *, force: bool) -> dict[str, str]:
    available = set(files)
    resolved: dict[str, str] = {}
    for public_path, relative in config.get("aliases", {}).items():
        public_path = normalize_public_path(public_path)
        relative = safe_relative(relative)
        if relative not in available:
            raise SwError(f"Alias target is not included in the publish output: {relative}")
        target = internal_target(config["name"], relative)
        existing = kvs_get(public_path)
        if existing and existing != target and not force:
            raise SwError(
                f"{public_path} is already owned by {existing}. Use --force only if replacing it intentionally."
            )
        resolved[public_path] = target
    return resolved


def invalidate(paths: list[str]) -> None:
    unique = sorted(set(paths))
    if not unique:
        return
    aws(
        "cloudfront",
        "create-invalidation",
        "--distribution-id",
        GLOBAL_CONFIG["distribution_id"],
        "--paths",
        *unique,
    )


def publish(args: argparse.Namespace) -> None:
    try:
        root, config = find_project()
    except SwError:
        if not args.source:
            raise
        init_args = argparse.Namespace(
            source=args.source,
            name=args.name,
            url=args.url,
            entry=None,
            install="",
            build="",
            force=False,
        )
        root, config = init_project(init_args)

    validate_name(config["name"])
    run_build(root, config)
    output, files = collect_files(root, config)
    aliases = validate_aliases(config, files, force=args.force)
    previous = read_registry(config["name"]) or {}

    with tempfile.TemporaryDirectory(prefix="sw-publish-") as temp:
        staging = Path(temp)
        for relative in files:
            destination = staging / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(output / relative, destination)
        print(f"Uploading {len(files)} file(s) for {config['name']}...")
        aws(
            "s3",
            "sync",
            f"{staging}/",
            f"s3://{GLOBAL_CONFIG['bucket']}/{GLOBAL_CONFIG['internal_prefix']}/{config['name']}/",
            "--delete",
            "--exclude",
            ".DS_Store",
        )

    etag = kvs_description()["ETag"]
    previous_aliases = previous.get("aliases", {})
    for public_path, old_target in previous_aliases.items():
        if public_path not in aliases and kvs_get(public_path) == old_target:
            etag = kvs_delete(public_path, etag)
    for public_path, target in aliases.items():
        if kvs_get(public_path) != target:
            etag = kvs_put(public_path, target, etag)

    now = datetime.now(timezone.utc).isoformat()
    registry = {
        "version": 1,
        "name": config["name"],
        "source": str(root),
        "publishedAt": now,
        "files": files,
        "aliases": aliases,
    }
    write_registry(registry)
    invalidate([*aliases, f"/{GLOBAL_CONFIG['internal_prefix']}/{config['name']}/*"])

    if aliases:
        for public_path in aliases:
            print(f"Published: {GLOBAL_CONFIG['domain']}{public_path}")
    else:
        print(
            f"Published: {GLOBAL_CONFIG['domain']}/{GLOBAL_CONFIG['internal_prefix']}/{config['name']}/"
        )


def list_projects(_args: argparse.Namespace) -> None:
    raw = aws(
        "s3api",
        "list-objects-v2",
        "--bucket",
        GLOBAL_CONFIG["bucket"],
        "--prefix",
        f"{REGISTRY_PREFIX}/",
        "--output",
        "json",
        capture=True,
    )
    objects = json.loads(raw).get("Contents", [])
    if not objects:
        print("No misc projects are published.")
        return
    for item in sorted(objects, key=lambda value: value["Key"]):
        name = Path(item["Key"]).stem
        registry = read_registry(name) or {}
        aliases = registry.get("aliases", {})
        url = next(iter(aliases), f"/{GLOBAL_CONFIG['internal_prefix']}/{name}/")
        print(f"{name:24} {GLOBAL_CONFIG['domain']}{url}")


def status(_args: argparse.Namespace) -> None:
    root, config = find_project()
    registry = read_registry(config["name"])
    if not registry:
        print(f"{config['name']} is not published.")
        return
    print(f"Project:   {config['name']}")
    print(f"Source:    {root}")
    print(f"Published: {registry['publishedAt']}")
    for public_path in registry.get("aliases", {}):
        url = f"{GLOBAL_CONFIG['domain']}{public_path}"
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                print(f"Live:      {response.status} {url}")
        except urllib.error.URLError as exc:
            print(f"Live:      ERROR {url} ({exc})")


def open_project(_args: argparse.Namespace) -> None:
    _root, config = find_project()
    registry = read_registry(config["name"])
    if not registry:
        raise SwError(f"{config['name']} is not published.")
    aliases = registry.get("aliases", {})
    path = next(iter(aliases), f"/{GLOBAL_CONFIG['internal_prefix']}/{config['name']}/")
    url = f"{GLOBAL_CONFIG['domain']}{path}"
    print(url)
    webbrowser.open(url)


def unpublish(args: argparse.Namespace) -> None:
    _root, config = find_project()
    name = config["name"]
    registry = read_registry(name)
    if not registry:
        print(f"{name} is not published.")
        return
    if not args.yes:
        answer = input(f"Remove {name} and all its public aliases? [y/N] ")
        if answer.lower() != "y":
            print("Cancelled.")
            return

    etag = kvs_description()["ETag"]
    removed_paths: list[str] = []
    for public_path, target in registry.get("aliases", {}).items():
        if kvs_get(public_path) == target:
            etag = kvs_delete(public_path, etag)
            removed_paths.append(public_path)
    aws("s3", "rm", f"s3://{GLOBAL_CONFIG['bucket']}/{GLOBAL_CONFIG['internal_prefix']}/{name}/", "--recursive")
    aws("s3", "rm", f"s3://{GLOBAL_CONFIG['bucket']}/{registry_key(name)}")
    invalidate([*removed_paths, f"/{GLOBAL_CONFIG['internal_prefix']}/{name}/*"])
    print(f"Unpublished {name}.")


def preview(_args: argparse.Namespace) -> None:
    import http.server
    import socketserver

    root, config = find_project()
    run_build(root, config)
    output, _files = collect_files(root, config)
    os.chdir(output)
    port = 8765
    entry = config.get("entry", "index.html")
    url = f"http://127.0.0.1:{port}/{entry}"
    print(f"Preview: {url}")
    webbrowser.open(url)
    with socketserver.TCPServer(("127.0.0.1", port), http.server.SimpleHTTPRequestHandler) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="sw", description="Publish standalone sites to seanwade.com")
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_cmd = subparsers.add_parser("init", help="Configure the current project")
    init_cmd.add_argument("source", nargs="?", default=".")
    init_cmd.add_argument("--name")
    init_cmd.add_argument("--url", help="Optional root URL alias, such as /demo.html")
    init_cmd.add_argument("--entry")
    init_cmd.add_argument("--install")
    init_cmd.add_argument("--build")
    init_cmd.add_argument("--force", action="store_true")
    init_cmd.set_defaults(func=lambda args: init_project(args))

    publish_cmd = subparsers.add_parser("publish", help="Build and publish the current project")
    publish_cmd.add_argument("source", nargs="?")
    publish_cmd.add_argument("--name")
    publish_cmd.add_argument("--url")
    publish_cmd.add_argument("--force", action="store_true")
    publish_cmd.set_defaults(func=publish)

    preview_cmd = subparsers.add_parser("preview", help="Build and preview locally")
    preview_cmd.set_defaults(func=preview)

    status_cmd = subparsers.add_parser("status", help="Check the current project's live deployment")
    status_cmd.set_defaults(func=status)

    list_cmd = subparsers.add_parser("list", help="List published misc projects")
    list_cmd.set_defaults(func=list_projects)

    open_cmd = subparsers.add_parser("open", help="Open the current project's public URL")
    open_cmd.set_defaults(func=open_project)

    remove_cmd = subparsers.add_parser("unpublish", help="Remove the current project from the site")
    remove_cmd.add_argument("--yes", action="store_true")
    remove_cmd.set_defaults(func=unpublish)
    return parser


def main() -> int:
    try:
        args = build_parser().parse_args()
        args.func(args)
        return 0
    except SwError as exc:
        print(f"sw: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
