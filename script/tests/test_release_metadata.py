import base64
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from xcode_build_metadata import generate_metadata
from validate_appcast import validate
from prepare_github_appcast import prepare
import xml.etree.ElementTree as ET


class ReleaseMetadataTests(unittest.TestCase):
    def test_update_configuration_requires_https_and_valid_key(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Configuration').mkdir()
            (root / 'Configuration/GitPico-Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.0.1', 'LSMinimumSystemVersion': '26.0'}))
            env = {'SRCROOT': folder, 'DERIVED_FILE_DIR': str(root / 'derived'),
                   'GITPICO_UPDATE_FEED_URL': 'https://updates.example.invalid/appcast.xml',
                   'GITPICO_UPDATE_PUBLIC_KEY': base64.b64encode(bytes(32)).decode()}
            build = generate_metadata(env)
            value = plistlib.loads((root / 'derived/GitPico-Info.plist').read_bytes())
            self.assertEqual(value['CFBundleShortVersionString'], '0.0.1')
            self.assertEqual(value['LSMinimumSystemVersion'], '26.0')
            self.assertEqual(len(build), 14)
            self.assertTrue(value['SUVerifyUpdateBeforeExtraction'])
            env['GITPICO_UPDATE_FEED_URL'] = 'http://updates.example.invalid/appcast.xml'
            with self.assertRaises(ValueError):
                generate_metadata(env)

    def test_appcast_rejects_unsigned_or_wrong_build(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / 'appcast.xml'
            signature = base64.b64encode(bytes(64)).decode()
            file.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="https://updates.example.invalid/a.zip" sparkle:version="20261026000000" sparkle:edSignature="' + signature + '" length="42" /></item></channel></rss>')
            validate(file, '20261026000000')
            with self.assertRaises(ValueError):
                validate(file, '20261026000001')
            file.write_text(file.read_text().replace(signature, ''))
            with self.assertRaises(ValueError):
                validate(file, '20261026000000')

    def test_private_release_feed_uses_exact_asset_id_and_preserves_signature_field(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / 'appcast.xml'
            signature = base64.b64encode(bytes(64)).decode()
            file.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>20261026000000</sparkle:version><sparkle:releaseNotesLink>https://other.invalid/notes</sparkle:releaseNotesLink><enclosure url="https://updates.example.invalid/a.zip" sparkle:edSignature="' + signature + '" length="42" /></item></channel></rss>')
            prepare(file, '20261026000000', 'example/private', '123')
            validate(file, '20261026000000')
            root = ET.parse(file).getroot()
            self.assertEqual(root.find('.//enclosure').get('url'), 'https://api.github.com/repos/example/private/releases/assets/123')
            self.assertNotIn('other.invalid', file.read_text())
            with self.assertRaises(ValueError): prepare(file, '20261026000001', 'example/private', '123')
            with self.assertRaises(ValueError): prepare(file, '20261026000000', '../private', '123')
            with self.assertRaises(ValueError): prepare(file, '20261026000000', 'example/private', '0')

    def test_github_configuration_derives_feed_without_embedding_credentials(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Configuration').mkdir()
            (root / 'Configuration/GitPico-Info.plist').write_bytes(plistlib.dumps({'GitPicoUpdateRepository': 'example/private', 'CFBundleShortVersionString': '0.0.1'}))
            generate_metadata({'SRCROOT': folder, 'DERIVED_FILE_DIR': str(root / 'derived'), 'GITPICO_UPDATE_PUBLIC_KEY': base64.b64encode(bytes(32)).decode()})
            value = plistlib.loads((root / 'derived/GitPico-Info.plist').read_bytes())
            self.assertEqual(value['SUFeedURL'], 'https://github.com/example/private/releases/latest/download/appcast.xml')
            self.assertTrue(value['SURequireSignedFeed'])
            self.assertTrue(value['SUEnableAutomaticChecks'])
            self.assertTrue(value['SUAutomaticallyUpdate'])
            self.assertEqual(value['SUScheduledCheckInterval'], 3600)

    def test_public_feed_uses_direct_download_without_rest_quota(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / 'appcast.xml'
            signature = base64.b64encode(bytes(64)).decode()
            file.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>20261027170000</sparkle:version><enclosure url="https://other.invalid/archive.zip" sparkle:edSignature="' + signature + '" length="42" /></item></channel></rss>')
            prepare(file, '20261027170000', 'example/public', '123', 'public')
            validate(file, '20261027170000')
            self.assertEqual(ET.parse(file).find('.//enclosure').get('url'), 'https://github.com/example/public/releases/download/build-20261027170000/GitPico-20261027170000.zip')
            with self.assertRaises(ValueError): prepare(file, '20261027170000', 'example/public', '123', 'other')

    def test_normal_xcode_build_uses_committed_public_update_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Configuration').mkdir()
            (root / 'Configuration/GitPico-Info.plist').write_bytes(plistlib.dumps({'GitPicoUpdateRepository': 'example/private', 'CFBundleShortVersionString': '0.0.1'}))
            key = base64.b64encode(bytes(32)).decode()
            (root / 'Configuration/SparklePublicKey.txt').write_text(key + '\n')
            env = {'SRCROOT': folder, 'DERIVED_FILE_DIR': str(root / 'derived')}
            generate_metadata(env)
            value = plistlib.loads((root / 'derived/GitPico-Info.plist').read_bytes())
            self.assertEqual(value['SUPublicEDKey'], key)
            self.assertEqual(value['SUFeedURL'], 'https://github.com/example/private/releases/latest/download/appcast.xml')
            self.assertTrue(value['SURequireSignedFeed'])
            self.assertTrue(value['SUEnableAutomaticChecks'])
            self.assertTrue(value['SUAutomaticallyUpdate'])
            self.assertEqual(value['SUScheduledCheckInterval'], 3600)
            env['GITPICO_UPDATE_PUBLIC_KEY'] = ''
            generate_metadata(env)
            value = plistlib.loads((root / 'derived/GitPico-Info.plist').read_bytes())
            self.assertNotIn('SUFeedURL', value)
            self.assertNotIn('SUPublicEDKey', value)


if __name__ == '__main__':
    unittest.main()
