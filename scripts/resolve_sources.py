#!/usr/bin/env python3
"""Resolve one consistent KSU/Manager snapshot per run, without executing API data."""
import argparse
import datetime
import json
import os
import re
import shlex
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPOSITORY = 'KernelSU-Next/KernelSU-Next'
SHA = re.compile(r'[0-9a-f]{40}')
VERSION = re.compile(r'v\d+\.\d+\.\d+')


class GitHub:
    def get(self, url, api=False):
        headers = {'User-Agent': 'cannon-kernel-build', 'Accept': 'application/vnd.github+json' if api else 'text/plain'}
        if api and os.environ.get('GH_TOKEN'):
            headers['Authorization'] = 'Bearer ' + os.environ['GH_TOKEN']
        request = urllib.request.Request(url, headers=headers)
        for attempt in range(3):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    return response.read().decode('utf-8')
            except urllib.error.HTTPError as error:
                if error.code not in (429, 500, 502, 503, 504) or attempt == 2:
                    raise
            except (urllib.error.URLError, TimeoutError):
                if attempt == 2:
                    raise
            time.sleep(2 ** attempt)
        raise RuntimeError('Download retries exhausted')

    def api(self, path):
        return json.loads(self.get(f'https://api.github.com/repos/{REPOSITORY}/{path}', api=True))

    def raw(self, commit, path):
        return self.get(f'https://raw.githubusercontent.com/{REPOSITORY}/{commit}/{path}')

    def commit(self, ref):
        commit = self.api('commits/' + urllib.parse.quote(ref, safe=''))['sha']
        if not SHA.fullmatch(commit):
            raise ValueError('GitHub returned an invalid commit SHA')
        return commit

    def branch(self, ref):
        # GitHub's branch endpoint follows renamed-branch redirects; the
        # commits endpoint can instead return 422 for the old branch name.
        commit = self.api('branches/' + urllib.parse.quote(ref, safe=''))['commit']['sha']
        if not SHA.fullmatch(commit):
            raise ValueError('GitHub returned an invalid branch commit SHA')
        return commit


def parse_uapi(text):
    match = re.search(r'\bKERNEL_SU_UAPI_VERSION\s*(?:=\s*)?(\d+)', text)
    if not match:
        raise ValueError('Cannot determine upstream UAPI version; integration needs review')
    return int(match[1])


def select_manager(release):
    version = release.get('tag_name', '')
    if release.get('draft') or release.get('prerelease') or not VERSION.fullmatch(version):
        raise ValueError('Latest release must be a published stable version')
    pattern = re.compile(r'KernelSU_Next_' + re.escape(version) + r'_\d+-release\.apk')
    candidates = [asset for asset in release.get('assets', []) if pattern.fullmatch(asset.get('name', ''))]
    if len(candidates) != 1:
        raise ValueError('Expected exactly one official standard Manager APK (not spoofed/debug)')
    asset = candidates[0]
    url = asset.get('browser_download_url', '')
    expected_url = f'https://github.com/{REPOSITORY}/releases/download/{version}/{asset["name"]}'
    if url != expected_url:
        raise ValueError('Unexpected Manager download URL')
    digest = asset.get('digest', '') or ''
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        raise ValueError('Official APK SHA-256 digest is unavailable; refusing an unchecked download')
    return version, url, digest.removeprefix('sha256:')


def resolve(config, mode, github):
    if mode == 'latest':
        version, manager_url, manager_digest = select_manager(github.api('releases/latest'))
        ksu_commit = github.branch(config['KSU_REF'])
        setup_commit = github.branch(config['KSU_SETUP_REF'])
        manager_commit = github.commit(version)
    elif mode == 'pinned':
        ksu_commit = config['PINNED_KSU_COMMIT']
        setup_commit = config['PINNED_KSU_SETUP_COMMIT']
        version = config['PINNED_MANAGER_VERSION']
        manager_commit = config['PINNED_MANAGER_SOURCE_COMMIT']
        manager_url = config['PINNED_MANAGER_URL']
        manager_digest = config['PINNED_MANAGER_SHA256']
    else:
        raise ValueError('Source mode must be latest or pinned')
    for commit in (ksu_commit, setup_commit, manager_commit):
        if not SHA.fullmatch(commit):
            raise ValueError('Expected a full commit SHA')
    if not VERSION.fullmatch(version) or not re.fullmatch(r'[0-9a-f]{64}', manager_digest):
        raise ValueError('Invalid Manager version or SHA-256')
    kernel_uapi = parse_uapi(github.raw(ksu_commit, 'uapi/supercall.h'))
    manager_uapi = parse_uapi(github.raw(manager_commit, 'uapi/supercall.h'))
    if kernel_uapi != manager_uapi:
        raise ValueError(f'Legacy UAPI {kernel_uapi} and Manager UAPI {manager_uapi} differ; '
                         'wait for upstream compatibility or explicitly select pinned mode')
    natives = github.raw(manager_commit, 'manager/app/src/main/java/com/rifsxd/ksunext/Natives.kt')
    minimum = re.search(r'\bMINIMAL_SUPPORTED_KERNEL\s*=\s*(\d+)', natives)
    if not minimum:
        raise ValueError('Cannot determine Manager minimum driver version; integration needs review')
    return {
        'KSU_SOURCE_MODE': mode,
        'KSU_SELECTED_REF': config['KSU_REF'] if mode == 'latest' else ksu_commit,
        'KSU_COMMIT': ksu_commit,
        'KSU_SETUP_COMMIT': setup_commit,
        'MANAGER_VERSION': version,
        'MANAGER_SOURCE_COMMIT': manager_commit,
        'MANAGER_URL': manager_url,
        'MANAGER_SHA256': manager_digest,
        'KSU_UAPI_VERSION': str(kernel_uapi),
        'MANAGER_UAPI_VERSION': str(manager_uapi),
        'MANAGER_MIN_KERNEL_VERSION': minimum[1],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--mode', choices=('latest', 'pinned'), default='latest')
    args = parser.parse_args()
    config = {}
    for line in args.config.read_text(encoding='utf-8').splitlines():
        if line.strip() and not line.lstrip().startswith('#'):
            key, value = line.split('=', 1)
            config[key.strip()] = value.strip()
    selected = resolve(config, args.mode, GitHub())
    args.output_dir.mkdir(parents=True, exist_ok=True)
    # Only the validated shell variables above are executable input to Bash.
    environment = ''.join(f'{key}={shlex.quote(value)}\n' for key, value in selected.items())
    (args.output_dir / 'resolved-sources.env').write_text(environment, encoding='utf-8', newline='\n')
    record = dict(selected, resolved_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
    (args.output_dir / 'resolved-sources.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, urllib.error.URLError) as error:
        print(f'ERROR: upstream source resolution failed: {error}', file=sys.stderr)
        sys.exit(1)
