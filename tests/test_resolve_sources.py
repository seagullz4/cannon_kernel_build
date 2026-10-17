import copy
import unittest

from scripts.resolve_sources import GitHub, parse_uapi, resolve, select_manager


def release():
    name = 'KernelSU_Next_v3.4.2_33355-release.apk'
    return {
        'tag_name': 'v3.4.2', 'draft': False, 'prerelease': False,
        'assets': [
            {'name': 'KernelSU_Next_v3.4.2-spoofed_33355-release.apk'},
            {'name': name, 'digest': 'sha256:' + 'a' * 64,
             'browser_download_url': 'https://github.com/KernelSU-Next/KernelSU-Next/releases/download/v3.4.2/' + name},
        ],
    }


class FakeGitHub:
    def __init__(self, kernel_uapi=5, manager_uapi=5):
        self.calls = []
        self.kernel_uapi = kernel_uapi
        self.manager_uapi = manager_uapi

    def api(self, path):
        self.calls.append(path)
        if path == 'releases/latest':
            return release()
        raise AssertionError(path)

    def commit(self, ref):
        self.calls.append(ref)
        return {'legacy': '1' * 40, 'next': '2' * 40, 'v3.4.2': '3' * 40}[ref]

    branch = commit

    def raw(self, commit, path):
        if path == 'uapi/supercall.h':
            if commit == '1' * 40:
                return '#define KERNEL_SU_UAPI_VERSION ' + str(self.kernel_uapi)
            return 'static const __u32 KERNEL_SU_UAPI_VERSION = ' + str(self.manager_uapi) + ';'
        return 'const val MINIMAL_SUPPORTED_KERNEL = 33188'


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            'KSU_REF': 'legacy', 'KSU_SETUP_REF': 'next',
            'PINNED_KSU_COMMIT': '1' * 40, 'PINNED_KSU_SETUP_COMMIT': '2' * 40,
            'PINNED_MANAGER_SOURCE_COMMIT': '3' * 40, 'PINNED_MANAGER_VERSION': 'v3.4.2',
            'PINNED_MANAGER_URL': release()['assets'][1]['browser_download_url'],
            'PINNED_MANAGER_SHA256': 'a' * 64,
        }

    def test_standard_apk_selected_instead_of_spoofed(self):
        version, url, digest = select_manager(release())
        self.assertEqual(version, 'v3.4.2')
        self.assertNotIn('spoofed', url)
        self.assertEqual(digest, 'a' * 64)

    def test_missing_digest_is_not_silently_bypassed(self):
        data = release()
        del data['assets'][1]['digest']
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            select_manager(data)

    def test_ambiguous_assets_are_rejected(self):
        data = release()
        data['assets'].append(copy.deepcopy(data['assets'][1]))
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            select_manager(data)

    def test_prerelease_is_rejected(self):
        data = release()
        data['prerelease'] = True
        with self.assertRaisesRegex(ValueError, 'stable'):
            select_manager(data)

    def test_unofficial_download_host_is_rejected(self):
        data = release()
        data['assets'][1]['browser_download_url'] = 'https://example.com/manager.apk'
        with self.assertRaisesRegex(ValueError, 'URL'):
            select_manager(data)

    def test_both_supported_uapi_declaration_styles(self):
        self.assertEqual(parse_uapi('#define KERNEL_SU_UAPI_VERSION 5'), 5)
        self.assertEqual(parse_uapi('static const __u32 KERNEL_SU_UAPI_VERSION = 5;'), 5)

    def test_unknown_uapi_format_requires_review(self):
        with self.assertRaisesRegex(ValueError, 'UAPI'):
            parse_uapi('// no version here')

    def test_latest_resolves_each_ref_once(self):
        github = FakeGitHub()
        selected = resolve(self.config, 'latest', github)
        self.assertEqual(selected['KSU_COMMIT'], '1' * 40)
        self.assertEqual(selected['KSU_SOURCE_MODE'], 'latest')
        self.assertEqual(selected['MANAGER_MIN_KERNEL_VERSION'], '33188')
        self.assertEqual(github.calls, ['releases/latest', 'legacy', 'next', 'v3.4.2'])

    def test_branch_lookup_uses_endpoint_with_rename_redirects(self):
        github = GitHub()
        paths = []
        def api(path):
            paths.append(path)
            return {'commit': {'sha': '2' * 40}}
        github.api = api
        self.assertEqual(github.branch('next'), '2' * 40)
        self.assertEqual(paths, ['branches/next'])

    def test_uapi_mismatch_stops_instead_of_falling_back(self):
        with self.assertRaisesRegex(ValueError, 'differ'):
            resolve(self.config, 'latest', FakeGitHub(manager_uapi=6))

    def test_pinned_does_not_query_latest(self):
        github = FakeGitHub()
        selected = resolve(self.config, 'pinned', github)
        self.assertEqual(selected['KSU_COMMIT'], self.config['PINNED_KSU_COMMIT'])
        self.assertEqual(selected['KSU_SOURCE_MODE'], 'pinned')
        self.assertEqual(github.calls, [])


if __name__ == '__main__':
    unittest.main()
