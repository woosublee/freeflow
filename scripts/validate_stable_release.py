#!/usr/bin/env python3
import argparse
import dataclasses
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from typing import Callable, Iterable, Optional, Sequence, Tuple


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION_COMPONENT = r"(?:0|[1-9]\d*)"
STABLE_TAG_PATTERN = re.compile(
    rf"^v({VERSION_COMPONENT})\.({VERSION_COMPONENT})\.({VERSION_COMPONENT})$"
)
STABLE_VERSION_PATTERN = re.compile(
    rf"^({VERSION_COMPONENT})\.({VERSION_COMPONENT})\.({VERSION_COMPONENT})$"
)
PRERELEASE_TAG_PATTERN = re.compile(
    rf"^v({VERSION_COMPONENT})\.({VERSION_COMPONENT})\.({VERSION_COMPONENT})"
    rf"-(?:alpha|beta|rc)\.({VERSION_COMPONENT})$"
)
BUILD_NUMBER_ASSIGNMENT_PATTERN = re.compile(
    r"^BUILD_NUMBER\s*(\?=|:=|=)\s*(.*?)\s*$"
)
SPARKLE_ADOPTION_VERSION = (0, 1, 6)


class ValidationError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class StableReleaseRecord:
    tag: str
    version: Tuple[int, int, int]
    build_number: Optional[int]


@dataclasses.dataclass(frozen=True)
class PublishedBuildRecord:
    tag: str
    build_number: int


@dataclasses.dataclass(frozen=True)
class AppcastMetadata:
    build_number: int
    display_version: str
    enclosure_url: str


def parse_version(value: str) -> Tuple[int, int, int]:
    match = STABLE_VERSION_PATTERN.fullmatch(value)
    if match is None:
        raise ValidationError(f"Stable version must use X.Y.Z: {value}")
    return tuple(int(part) for part in match.groups())


def parse_stable_tag(value: str) -> Optional[Tuple[int, int, int]]:
    match = STABLE_TAG_PATTERN.fullmatch(value)
    if match is None:
        return None
    return tuple(int(part) for part in match.groups())


def parse_prerelease_tag(value: str) -> Optional[Tuple[int, int, int]]:
    match = PRERELEASE_TAG_PATTERN.fullmatch(value)
    if match is None:
        return None
    return tuple(int(part) for part in match.groups()[:3])


def parse_positive_build(value: object, context: str) -> int:
    try:
        build_number = int(str(value))
    except (TypeError, ValueError) as error:
        raise ValidationError(f"{context} must be a positive integer: {value}") from error
    if build_number <= 0:
        raise ValidationError(f"{context} must be a positive integer: {value}")
    return build_number


def validate_preflight(
    candidate_version: str,
    candidate_build: int,
    records: Iterable[StableReleaseRecord],
    additional_build_records: Iterable[PublishedBuildRecord] = (),
) -> None:
    parsed_candidate = parse_version(candidate_version)
    candidate_build = parse_positive_build(candidate_build, "Candidate build")
    records = list(records)
    if records:
        highest_version_record = max(records, key=lambda record: record.version)
        if parsed_candidate <= highest_version_record.version:
            raise ValidationError(
                f"Candidate version {candidate_version} must be greater than "
                f"{highest_version_record.tag}"
            )

    build_records = [
        PublishedBuildRecord(record.tag, record.build_number)
        for record in records
        if record.build_number is not None
    ]
    build_records.extend(additional_build_records)
    if not build_records:
        return

    highest_build_record = max(
        build_records,
        key=lambda record: record.build_number,
    )
    if candidate_build <= highest_build_record.build_number:
        raise ValidationError(
            f"Candidate build {candidate_build} must be greater than build "
            f"{highest_build_record.build_number} from {highest_build_record.tag}"
        )


def collect_stable_release_records(
    releases: Sequence[dict],
    appcast_loader: Callable[[str], bytes],
) -> list[StableReleaseRecord]:
    stable_releases = []
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue

        tag = release.get("tag_name")
        version = parse_stable_tag(tag) if isinstance(tag, str) else None
        if version is None:
            continue

        appcast_assets = [
            asset
            for asset in release.get("assets", [])
            if asset.get("name") == "appcast.xml"
        ]
        if len(appcast_assets) > 1:
            raise ValidationError(f"Release {tag} has multiple appcast.xml assets")
        stable_releases.append((tag, version, appcast_assets))

    records = []
    for tag, version, appcast_assets in stable_releases:
        if not appcast_assets:
            if version >= SPARKLE_ADOPTION_VERSION:
                raise ValidationError(
                    f"Release {tag} is missing appcast.xml after Sparkle adoption"
                )
            records.append(StableReleaseRecord(tag, version, None))
            continue

        appcast_url = appcast_assets[0].get("browser_download_url")
        if not appcast_url:
            raise ValidationError(f"Release {tag} appcast.xml has no download URL")
        try:
            appcast = parse_appcast(appcast_loader(appcast_url))
        except ValidationError:
            raise
        except Exception as error:
            raise ValidationError(f"Unable to load appcast.xml for {tag}: {error}") from error
        expected_display_version = tag.removeprefix("v")
        if appcast.display_version != expected_display_version:
            raise ValidationError(
                f"Release {tag} appcast display version {appcast.display_version} "
                f"does not match {expected_display_version}"
            )
        records.append(StableReleaseRecord(tag, version, appcast.build_number))

    return records


def parse_make_build_number(metadata_text: str, context: str) -> int:
    build_number = None
    for raw_line in metadata_text.splitlines():
        line = raw_line.split("#", maxsplit=1)[0].strip()
        if not line or not line.startswith("BUILD_NUMBER"):
            continue
        match = BUILD_NUMBER_ASSIGNMENT_PATTERN.fullmatch(line)
        if match is None:
            raise ValidationError(f"{context} uses an unsupported BUILD_NUMBER assignment")
        operator, value = match.groups()
        parsed_value = parse_positive_build(value, f"{context} build")
        if operator != "?=" or build_number is None:
            build_number = parsed_value
    if build_number is None:
        raise ValidationError(f"{context} has no BUILD_NUMBER")
    return build_number


def collect_prerelease_build_records(
    releases: Sequence[dict],
    version_metadata_loader: Callable[[str], Optional[bytes]],
    first_appcast_version: Optional[Tuple[int, int, int]],
) -> list[PublishedBuildRecord]:
    records = []
    for release in releases:
        if release.get("draft") or not release.get("prerelease"):
            continue

        tag = release.get("tag_name")
        version = None
        if isinstance(tag, str):
            version = parse_prerelease_tag(tag) or parse_stable_tag(tag)
        if version is None:
            continue

        metadata = version_metadata_loader(tag)
        if metadata is None:
            if first_appcast_version is not None and version >= first_appcast_version:
                raise ValidationError(
                    f"Prerelease {tag} is missing version.mk after Sparkle adoption"
                )
            continue

        try:
            metadata_text = metadata.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ValidationError(f"Prerelease {tag} version.mk is not UTF-8") from error
        records.append(
            PublishedBuildRecord(
                tag,
                parse_make_build_number(metadata_text, f"Prerelease {tag} version.mk"),
            )
        )
    return records


def parse_appcast(data: bytes) -> AppcastMetadata:
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise ValidationError(f"Invalid appcast XML: {error}") from error

    item = root.find("./channel/item")
    if item is None:
        raise ValidationError("Appcast is missing channel/item")

    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValidationError("Appcast item is missing enclosure")

    namespace = f"{{{SPARKLE_NS}}}"
    element_build = item.findtext(f"{namespace}version")
    attribute_build = enclosure.get(f"{namespace}version")
    build_value = element_build or attribute_build
    if build_value is None:
        raise ValidationError("Appcast item is missing sparkle:version")
    if element_build and attribute_build and element_build != attribute_build:
        raise ValidationError("Appcast item and enclosure use different build numbers")

    element_version = item.findtext(f"{namespace}shortVersionString")
    attribute_version = enclosure.get(f"{namespace}shortVersionString")
    display_version = element_version or attribute_version
    if not display_version:
        raise ValidationError("Appcast item is missing sparkle:shortVersionString")
    if element_version and attribute_version and element_version != attribute_version:
        raise ValidationError("Appcast item and enclosure use different display versions")
    parse_version(display_version)

    enclosure_url = enclosure.get("url")
    if not enclosure_url:
        raise ValidationError("Appcast enclosure is missing url")

    return AppcastMetadata(
        build_number=parse_positive_build(build_value, "Appcast build"),
        display_version=display_version,
        enclosure_url=enclosure_url,
    )


def validate_latest(
    repository: str,
    expected_tag: str,
    expected_version: str,
    expected_build: int,
    actual_tag: str,
    appcast: AppcastMetadata,
) -> None:
    expected_build = parse_positive_build(expected_build, "Expected build")
    parse_version(expected_version)

    if actual_tag != expected_tag:
        raise ValidationError(
            f"GitHub latest tag {actual_tag} does not match expected {expected_tag}"
        )
    if appcast.display_version != expected_version:
        raise ValidationError(
            f"Latest appcast display version {appcast.display_version} does not match "
            f"expected {expected_version}"
        )
    if appcast.build_number != expected_build:
        raise ValidationError(
            f"Latest appcast build {appcast.build_number} does not match "
            f"expected {expected_build}"
        )

    expected_url = (
        f"https://github.com/{repository}/releases/download/"
        f"{expected_tag}/Quill.dmg"
    )
    if appcast.enclosure_url != expected_url:
        raise ValidationError(
            f"Latest appcast enclosure {appcast.enclosure_url} does not match "
            f"expected {expected_url}"
        )


def build_request(
    url: str,
    accept: str,
    token: Optional[str],
) -> urllib.request.Request:
    headers = {
        "Accept": accept,
        "User-Agent": "quill-release-validator",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.Request(url, headers=headers)


def github_request(
    url: str,
    accept: str,
    token: Optional[str] = None,
) -> bytes:
    request = build_request(url, accept, token)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise ValidationError(f"GitHub request failed with HTTP {error.code}: {url}") from error
    except urllib.error.URLError as error:
        raise ValidationError(f"GitHub request failed: {url}: {error.reason}") from error


def github_json(url: str, token: str):
    try:
        return json.loads(
            github_request(
                url,
                "application/vnd.github+json",
                token,
            ).decode("utf-8")
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"GitHub returned invalid JSON: {url}") from error


def download_public_bytes(url: str) -> bytes:
    return github_request(url, "application/octet-stream")


def download_optional_public_bytes(url: str) -> Optional[bytes]:
    try:
        return download_public_bytes(url)
    except ValidationError as error:
        if "HTTP 404" in str(error):
            return None
        raise


def version_metadata_url(repository: str, tag: str) -> str:
    encoded_tag = urllib.parse.quote(tag, safe="")
    return f"https://raw.githubusercontent.com/{repository}/{encoded_tag}/version.mk"


def run_with_retries(
    operation: Callable[[], object],
    attempts: int,
    retry_delay: float,
    sleep: Callable[[float], None] = time.sleep,
):
    if attempts < 1:
        raise ValidationError("Retry attempts must be at least 1")
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            return operation()
        except ValidationError as error:
            last_error = error
            if attempt == attempts:
                raise
            print(
                f"Verification attempt {attempt}/{attempts} failed: {error}; retrying",
                file=sys.stderr,
            )
            sleep(retry_delay)
    raise last_error


def fetch_all_releases(repository: str, token: str) -> list[dict]:
    releases = []
    page = 1
    while True:
        batch = github_json(
            f"https://api.github.com/repos/{repository}/releases?per_page=100&page={page}",
            token,
        )
        if not isinstance(batch, list):
            raise ValidationError("GitHub releases response must be an array")
        releases.extend(batch)
        if len(batch) < 100:
            return releases
        page += 1


def fetch_latest_release(repository: str, token: str) -> dict:
    release = github_json(
        f"https://api.github.com/repos/{repository}/releases/latest",
        token,
    )
    if not isinstance(release, dict):
        raise ValidationError("GitHub latest release response must be an object")
    return release


def latest_appcast_url(repository: str) -> str:
    return f"https://github.com/{repository}/releases/latest/download/appcast.xml"


def require_token() -> str:
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        raise ValidationError("GITHUB_TOKEN is required")
    return token


def run_preflight(args) -> None:
    token = require_token()
    releases = fetch_all_releases(args.repository, token)
    records = collect_stable_release_records(
        releases,
        download_public_bytes,
    )
    prerelease_builds = collect_prerelease_build_records(
        releases,
        lambda tag: download_optional_public_bytes(
            version_metadata_url(args.repository, tag)
        ),
        first_appcast_version=SPARKLE_ADOPTION_VERSION,
    )
    validate_preflight(
        args.candidate_version,
        args.candidate_build,
        records,
        prerelease_builds,
    )

    highest_version = max(records, key=lambda record: record.version, default=None)
    build_records = [
        PublishedBuildRecord(record.tag, record.build_number)
        for record in records
        if record.build_number is not None
    ]
    build_records.extend(prerelease_builds)
    highest_build = max(
        build_records,
        key=lambda record: record.build_number,
        default=None,
    )
    print(
        "Stable release preflight passed: "
        f"candidate={args.candidate_version}/{args.candidate_build}, "
        f"highest_version={highest_version.tag if highest_version else 'none'}, "
        f"highest_build={highest_build.build_number if highest_build else 'none'}"
    )


def run_verify_latest(args) -> None:
    token = require_token()

    def verify_once() -> None:
        release = fetch_latest_release(args.repository, token)
        appcast = parse_appcast(
            download_public_bytes(latest_appcast_url(args.repository))
        )
        validate_latest(
            repository=args.repository,
            expected_tag=args.expected_tag,
            expected_version=args.expected_version,
            expected_build=args.expected_build,
            actual_tag=release.get("tag_name", ""),
            appcast=appcast,
        )

    run_with_retries(
        verify_once,
        attempts=args.attempts,
        retry_delay=args.retry_delay,
    )
    print(
        "Latest release verification passed: "
        f"tag={args.expected_tag}, "
        f"version={args.expected_version}, "
        f"build={args.expected_build}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate Quill stable release ordering and latest appcast metadata."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    preflight = subparsers.add_parser("preflight")
    preflight.add_argument("--repository", required=True)
    preflight.add_argument("--candidate-version", required=True)
    preflight.add_argument("--candidate-build", required=True, type=int)
    preflight.set_defaults(handler=run_preflight)

    verify_latest = subparsers.add_parser("verify-latest")
    verify_latest.add_argument("--repository", required=True)
    verify_latest.add_argument("--expected-tag", required=True)
    verify_latest.add_argument("--expected-version", required=True)
    verify_latest.add_argument("--expected-build", required=True, type=int)
    verify_latest.add_argument("--attempts", type=int, default=1)
    verify_latest.add_argument("--retry-delay", type=float, default=10)
    verify_latest.set_defaults(handler=run_verify_latest)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.handler(args)
    except ValidationError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
