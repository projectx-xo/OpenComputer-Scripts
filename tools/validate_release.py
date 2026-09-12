#!/usr/bin/env python3

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
VERSION_SOURCE_RE = re.compile(
    r'^\s*local\s+VERSION\s*=\s*"([^"]+)"\s*$',
    re.MULTILINE,
)
LEAF_TABLE_RE = re.compile(
    r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{([^{}]*)\}",
    re.DOTALL,
)
FIELD_RE = re.compile(
    r'(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]*)"\s*,?\s*$'
)
PROTOCOL_RE = re.compile(r"(?m)^\s*protocol\s*=\s*(\d+)\s*,?\s*$")


class ValidationError(Exception):
    pass


def fail(message: str) -> None:
    raise ValidationError(message)


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def parse_semver(value: str, label: str) -> tuple[int, int, int]:
    value = value.strip()
    if not SEMVER_RE.fullmatch(value):
        fail(f"{label} must be x.y.z, got {value!r}")
    return tuple(int(part) for part in value.split("."))


def source_version(path: str) -> str:
    match = VERSION_SOURCE_RE.search(read_text(path))
    if not match:
        fail(f'{path}: missing local VERSION = "x.y.z"')
    value = match.group(1)
    parse_semver(value, f"{path} VERSION")
    return value


def version_file(path: str) -> str:
    value = read_text(path).strip()
    parse_semver(value, path)
    return value


def parse_manifest_text(text: str, label: str) -> dict[str, dict[str, str]]:
    protocol = PROTOCOL_RE.search(text)
    if not protocol:
        fail(f"{label}: missing numeric protocol")

    roles: dict[str, dict[str, str]] = {}
    for match in LEAF_TABLE_RE.finditer(text):
        role = match.group(1)
        fields = dict(FIELD_RE.findall(match.group(2)))
        if "version" not in fields and "path" not in fields:
            continue
        if "version" not in fields or "path" not in fields:
            fail(f"{label}: role {role!r} must contain version and path")
        if role in roles:
            fail(f"{label}: duplicate role {role!r}")

        version = fields["version"]
        path = fields["path"]
        parse_semver(version, f"{label} role {role} version")

        posix_path = PurePosixPath(path)
        if (
            posix_path.is_absolute()
            or ".." in posix_path.parts
            or not path.startswith("runtime/")
            or posix_path.suffix != ".lua"
        ):
            fail(
                f"{label}: role {role!r} path must be a relative runtime/*.lua "
                f"path without '..', got {path!r}"
            )

        roles[role] = {"version": version, "path": path}

    if not roles:
        fail(f"{label}: no runtime roles found")

    return roles


def parse_manifest(path: str = "runtime/manifest.lua") -> dict[str, dict[str, str]]:
    return parse_manifest_text(read_text(path), path)


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        fail(
            f"git {' '.join(args)} failed: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    return result.stdout


def git_show(base_sha: str, path: str) -> str | None:
    result = subprocess.run(
        ["git", "show", f"{base_sha}:{path}"],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def validate_current_tree() -> dict[str, dict[str, str]]:
    central_source = source_version("central/central.lua")
    central_file = version_file("central/version.txt")
    if central_source != central_file:
        fail(
            "central version mismatch: "
            f"central.lua={central_source}, version.txt={central_file}"
        )

    bootstrap_source = source_version("bootstrap/bootstrap.lua")
    bootstrap_file = version_file("bootstrap/version.txt")
    if bootstrap_source != bootstrap_file:
        fail(
            "bootstrap version mismatch: "
            f"bootstrap.lua={bootstrap_source}, version.txt={bootstrap_file}"
        )

    manifest = parse_manifest()
    for role, info in sorted(manifest.items()):
        runtime_path = ROOT / info["path"]
        if not runtime_path.is_file():
            fail(
                f"runtime/manifest.lua: role {role!r} references missing "
                f"{info['path']}"
            )

    return manifest


def validate_release_changes(
    base_sha: str,
    current_manifest: dict[str, dict[str, str]],
) -> None:
    if not base_sha or set(base_sha) == {"0"}:
        print("No base SHA available; skipping version-bump comparison.")
        return

    probe = subprocess.run(
        ["git", "cat-file", "-e", f"{base_sha}^{{commit}}"],
        cwd=ROOT,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if probe.returncode != 0:
        fail(
            f"base commit {base_sha} is not available; "
            "checkout must use fetch-depth: 0"
        )

    changed = {
        line.strip()
        for line in git("diff", "--name-only", base_sha, "HEAD").splitlines()
        if line.strip()
    }

    if "central/central.lua" in changed:
        old_text = git_show(base_sha, "central/version.txt")
        if old_text is None:
            fail("central/central.lua changed but base central/version.txt is missing")
        old = parse_semver(old_text.strip(), "base central/version.txt")
        new_text = version_file("central/version.txt")
        new = parse_semver(new_text, "central/version.txt")
        if "central/version.txt" not in changed:
            fail("central/central.lua changed without changing central/version.txt")
        if new <= old:
            fail(
                f"central version must increase when central.lua changes "
                f"({old_text.strip()} -> {new_text})"
            )

    if "bootstrap/bootstrap.lua" in changed:
        old_text = git_show(base_sha, "bootstrap/version.txt")
        if old_text is None:
            fail(
                "bootstrap/bootstrap.lua changed but base "
                "bootstrap/version.txt is missing"
            )
        old = parse_semver(old_text.strip(), "base bootstrap/version.txt")
        new_text = version_file("bootstrap/version.txt")
        new = parse_semver(new_text, "bootstrap/version.txt")
        if "bootstrap/version.txt" not in changed:
            fail(
                "bootstrap/bootstrap.lua changed without changing "
                "bootstrap/version.txt"
            )
        if new <= old:
            fail(
                f"bootstrap version must increase when bootstrap.lua changes "
                f"({old_text.strip()} -> {new_text})"
            )

    base_manifest_text = git_show(base_sha, "runtime/manifest.lua")
    if base_manifest_text is None:
        return
    base_manifest = parse_manifest_text(
        base_manifest_text,
        f"{base_sha}:runtime/manifest.lua",
    )

    for role in sorted(set(base_manifest) & set(current_manifest)):
        old_info = base_manifest[role]
        new_info = current_manifest[role]
        old_version = parse_semver(
            old_info["version"],
            f"base manifest role {role}",
        )
        new_version = parse_semver(
            new_info["version"],
            f"manifest role {role}",
        )

        if new_version < old_version:
            fail(
                f"runtime role {role!r} version regressed "
                f"({old_info['version']} -> {new_info['version']})"
            )

        runtime_changed = (
            old_info["path"] != new_info["path"]
            or old_info["path"] in changed
            or new_info["path"] in changed
        )
        if runtime_changed and new_version <= old_version:
            fail(
                f"runtime role {role!r} changed without a version increase "
                f"({old_info['version']} -> {new_info['version']})"
            )


def main() -> int:
    try:
        manifest = validate_current_tree()
        validate_release_changes(os.environ.get("BASE_SHA", "").strip(), manifest)
    except ValidationError as error:
        print(f"::error::{error}")
        return 1

    print("Release validation passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
