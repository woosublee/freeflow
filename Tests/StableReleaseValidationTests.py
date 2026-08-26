import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "scripts"))

import validate_stable_release as module


APPCAST_XML = """<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>31</sparkle:version>
    <sparkle:shortVersionString>0.1.28</sparkle:shortVersionString>
    <enclosure url="https://github.com/woosublee/quill/releases/download/v0.1.28/Quill.dmg"
      sparkle:version="31" sparkle:shortVersionString="0.1.28" />
  </item></channel>
</rss>"""


class StableReleaseValidationTests(unittest.TestCase):
    def records(self):
        return [
            module.StableReleaseRecord("v0.1.27", (0, 1, 27), 30),
            module.StableReleaseRecord("v0.1.28", (0, 1, 28), 31),
        ]

    def test_accepts_strictly_newer_version_and_build(self):
        module.validate_preflight("0.1.29", 32, self.records())

    def test_rejects_equal_or_lower_version(self):
        with self.assertRaises(module.ValidationError):
            module.validate_preflight("0.1.28", 32, self.records())

    def test_rejects_equal_or_lower_build(self):
        with self.assertRaises(module.ValidationError):
            module.validate_preflight("0.1.29", 31, self.records())

    def test_rejects_build_not_newer_than_published_prerelease(self):
        prerelease_builds = [
            module.PublishedBuildRecord("v0.2.0-beta.1", 40),
        ]

        with self.assertRaises(module.ValidationError):
            module.validate_preflight(
                "0.2.0",
                32,
                self.records(),
                prerelease_builds,
            )

    def test_uses_maximum_build_across_all_stable_records(self):
        records = [
            module.StableReleaseRecord("v0.1.28", (0, 1, 28), 31),
            module.StableReleaseRecord("v0.1.27", (0, 1, 27), 32),
        ]

        with self.assertRaises(module.ValidationError):
            module.validate_preflight("0.1.29", 32, records)

    def test_allows_first_stable_release(self):
        module.validate_preflight("0.1.0", 1, [])

    def test_collects_only_published_stable_releases(self):
        releases = [
            release("v0.1.28", APPCAST_XML),
            release("v0.1.29-beta.1", APPCAST_XML, prerelease=True),
            release("v0.1.30", APPCAST_XML, draft=True),
            release("not-a-version", APPCAST_XML),
            release("v0.1.5", None),
        ]

        records = module.collect_stable_release_records(
            releases,
            lambda url: APPCAST_XML.encode() if url else b"",
        )

        self.assertEqual(
            records,
            [
                module.StableReleaseRecord("v0.1.28", (0, 1, 28), 31),
                module.StableReleaseRecord("v0.1.5", (0, 1, 5), None),
            ],
        )

    def test_rejects_appcast_display_version_that_does_not_match_tag(self):
        mismatched_appcast = APPCAST_XML.replace("0.1.28", "0.1.30")

        with self.assertRaises(module.ValidationError):
            module.collect_stable_release_records(
                [release("v0.1.28", mismatched_appcast)],
                lambda url: mismatched_appcast.encode(),
            )

    def test_collects_prerelease_build_from_version_metadata(self):
        releases = [release("v0.2.0-beta.1", None, prerelease=True)]
        metadata = b"APP_VERSION := 0.2.0-beta.1\nBUILD_NUMBER := 40\n"

        records = module.collect_prerelease_build_records(
            releases,
            lambda tag: metadata,
            first_appcast_version=(0, 1, 6),
        )

        self.assertEqual(
            records,
            [module.PublishedBuildRecord("v0.2.0-beta.1", 40)],
        )

    def test_collects_manual_prerelease_with_stable_shaped_tag(self):
        releases = [release("v0.2.0", None, prerelease=True)]
        metadata = b"APP_VERSION := 0.2.0\nBUILD_NUMBER := 40\n"

        records = module.collect_prerelease_build_records(
            releases,
            lambda tag: metadata,
            first_appcast_version=(0, 1, 6),
        )

        self.assertEqual(
            records,
            [module.PublishedBuildRecord("v0.2.0", 40)],
        )

    def test_collects_moving_dev_release_build_from_version_metadata(self):
        releases = [release("dev", None, prerelease=True)]
        metadata = b"APP_VERSION := 0.1.41\nBUILD_NUMBER := 44\n"

        records = module.collect_prerelease_build_records(
            releases,
            lambda tag: metadata,
            first_appcast_version=(0, 1, 6),
        )

        self.assertEqual(
            records,
            [module.PublishedBuildRecord("dev", 44)],
        )

    def test_rejects_moving_dev_release_without_version_metadata(self):
        with self.assertRaises(module.ValidationError):
            module.collect_prerelease_build_records(
                [release("dev", None, prerelease=True)],
                lambda tag: None,
                first_appcast_version=(0, 1, 6),
            )

    def test_prerelease_build_parser_uses_last_make_assignment(self):
        releases = [release("v0.2.0-beta.1", None, prerelease=True)]
        metadata = b"BUILD_NUMBER := 40\nBUILD_NUMBER := 50\n"

        records = module.collect_prerelease_build_records(
            releases,
            lambda tag: metadata,
            first_appcast_version=(0, 1, 6),
        )

        self.assertEqual(
            records,
            [module.PublishedBuildRecord("v0.2.0-beta.1", 50)],
        )

    def test_prerelease_build_parser_supports_conditional_assignment(self):
        releases = [release("v0.2.0-beta.1", None, prerelease=True)]
        metadata = b"BUILD_NUMBER ?= 40\n"

        records = module.collect_prerelease_build_records(
            releases,
            lambda tag: metadata,
            first_appcast_version=(0, 1, 6),
        )

        self.assertEqual(
            records,
            [module.PublishedBuildRecord("v0.2.0-beta.1", 40)],
        )

    def test_allows_legacy_prerelease_without_version_metadata(self):
        records = module.collect_prerelease_build_records(
            [release("v0.1.0-beta.2", None, prerelease=True)],
            lambda tag: None,
            first_appcast_version=(0, 1, 6),
        )

        self.assertEqual(records, [])

    def test_rejects_new_prerelease_without_version_metadata(self):
        with self.assertRaises(module.ValidationError):
            module.collect_prerelease_build_records(
                [release("v0.2.0-beta.1", None, prerelease=True)],
                lambda tag: None,
                first_appcast_version=(0, 1, 6),
            )

    def test_rejects_missing_appcast_after_sparkle_adoption(self):
        releases = [
            release("v0.1.5", None),
            release("v0.1.6", APPCAST_XML),
            release("v0.1.7", None),
        ]

        with self.assertRaises(module.ValidationError):
            module.collect_stable_release_records(
                releases,
                lambda url: APPCAST_XML.encode() if url else b"",
            )

    def test_rejects_missing_first_sparkle_appcast(self):
        appcast_017 = APPCAST_XML.replace("0.1.28", "0.1.7")
        releases = [
            release("v0.1.6", None),
            release("v0.1.7", appcast_017),
        ]

        with self.assertRaises(module.ValidationError):
            module.collect_stable_release_records(
                releases,
                lambda url: appcast_017.encode(),
            )

    def test_rejects_leading_zero_version_components(self):
        with self.assertRaises(module.ValidationError):
            module.parse_version("0.01.29")

    def test_retries_transient_latest_verification_failure(self):
        attempts = []

        def operation():
            attempts.append(1)
            if len(attempts) < 3:
                raise module.ValidationError("not propagated yet")
            return "verified"

        result = module.run_with_retries(
            operation,
            attempts=3,
            retry_delay=0,
            sleep=lambda _: None,
        )

        self.assertEqual(result, "verified")
        self.assertEqual(len(attempts), 3)

    def test_stops_after_latest_verification_retries_are_exhausted(self):
        with self.assertRaises(module.ValidationError):
            module.run_with_retries(
                lambda: (_ for _ in ()).throw(module.ValidationError("still stale")),
                attempts=2,
                retry_delay=0,
                sleep=lambda _: None,
            )

    def test_public_asset_request_does_not_include_token(self):
        public_request = module.build_request(
            "https://github.com/woosublee/quill/releases/latest/download/appcast.xml",
            accept="application/octet-stream",
            token=None,
        )
        api_request = module.build_request(
            "https://api.github.com/repos/woosublee/quill/releases/latest",
            accept="application/vnd.github+json",
            token="secret-token",
        )

        self.assertIsNone(public_request.get_header("Authorization"))
        self.assertEqual(api_request.get_header("Authorization"), "Bearer secret-token")

    def test_latest_appcast_url_matches_application_feed(self):
        self.assertEqual(
            module.latest_appcast_url("woosublee/quill"),
            "https://github.com/woosublee/quill/releases/latest/download/appcast.xml",
        )

    def test_parses_appcast_version_and_enclosure(self):
        metadata = module.parse_appcast(APPCAST_XML.encode())

        self.assertEqual(metadata.build_number, 31)
        self.assertEqual(metadata.display_version, "0.1.28")
        self.assertEqual(
            metadata.enclosure_url,
            "https://github.com/woosublee/quill/releases/download/v0.1.28/Quill.dmg",
        )

    def test_rejects_malformed_existing_appcast(self):
        with self.assertRaises(module.ValidationError):
            module.parse_appcast(b"<rss><channel></channel></rss>")

    def test_accepts_expected_latest_release(self):
        module.validate_latest(
            repository="woosublee/quill",
            expected_tag="v0.1.28",
            expected_version="0.1.28",
            expected_build=31,
            actual_tag="v0.1.28",
            appcast=module.parse_appcast(APPCAST_XML.encode()),
        )

    def test_rejects_latest_release_with_wrong_tag(self):
        with self.assertRaises(module.ValidationError):
            module.validate_latest(
                repository="woosublee/quill",
                expected_tag="v0.1.29",
                expected_version="0.1.28",
                expected_build=31,
                actual_tag="v0.1.28",
                appcast=module.parse_appcast(APPCAST_XML.encode()),
            )

    def test_rejects_latest_appcast_with_wrong_display_version(self):
        with self.assertRaises(module.ValidationError):
            module.validate_latest(
                repository="woosublee/quill",
                expected_tag="v0.1.28",
                expected_version="0.1.29",
                expected_build=31,
                actual_tag="v0.1.28",
                appcast=module.parse_appcast(APPCAST_XML.encode()),
            )

    def test_rejects_latest_appcast_with_wrong_build(self):
        with self.assertRaises(module.ValidationError):
            module.validate_latest(
                repository="woosublee/quill",
                expected_tag="v0.1.28",
                expected_version="0.1.28",
                expected_build=32,
                actual_tag="v0.1.28",
                appcast=module.parse_appcast(APPCAST_XML.encode()),
            )

    def test_rejects_latest_appcast_with_wrong_enclosure(self):
        appcast = module.AppcastMetadata(
            build_number=31,
            display_version="0.1.28",
            enclosure_url="https://example.test/Quill.dmg",
        )

        with self.assertRaises(module.ValidationError):
            module.validate_latest(
                repository="woosublee/quill",
                expected_tag="v0.1.28",
                expected_version="0.1.28",
                expected_build=31,
                actual_tag="v0.1.28",
                appcast=appcast,
            )


def release(tag, appcast, draft=False, prerelease=False):
    assets = []
    if appcast is not None:
        assets.append(
            {
                "name": "appcast.xml",
                "browser_download_url": f"https://example.test/{tag}/appcast.xml",
            }
        )
    return {
        "tag_name": tag,
        "draft": draft,
        "prerelease": prerelease,
        "assets": assets,
    }


if __name__ == "__main__":
    unittest.main()
