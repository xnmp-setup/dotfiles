#!/usr/bin/env python3
"""Offline behavioral checks for CLI model/options contracts; no paid calls."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CLI = Path(__file__).with_name('image_gen.py')

class ImageCliContractTests(unittest.TestCase):
    def invoke(self, *options, command='generate'):
        env = {key: value for key, value in os.environ.items() if key != 'OPENAI_API_KEY'}
        with tempfile.TemporaryDirectory() as workspace:
            return subprocess.run(
                [sys.executable, str(CLI), command, '--prompt', 'A coral reef',
                 '--dry-run', '--no-augment', *options],
                cwd=workspace, env=env, text=True, capture_output=True,
            )

    def payload(self, *options):
        result = self.invoke(*options)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_default_generates_with_flare(self):
        payload = self.payload('--size', '3440x1440')
        self.assertEqual(payload['model'], 'gpt-image-2.5-flare')
        self.assertEqual(payload['size'], '3440x1440')
        self.assertEqual(payload['endpoint'], '/v1/images/generations')

    def test_explicit_modern_models_and_snapshots_keep_custom_size(self):
        for model in ['gpt-image-2.5-flare', 'gpt-image-2.5-sunburst',
                      'gpt-image-2.5-sunburst-2026-09-08', 'gpt-image-2-2026-04-21']:
            with self.subTest(model=model):
                payload = self.payload('--model', model, '--size', '3440x1440')
                self.assertEqual((payload['model'], payload['size']), (model, '3440x1440'))

    def test_2_5_extended_quality_is_forwarded(self):
        for quality in ['xhigh', 'max']:
            self.assertEqual(self.payload('--quality', quality)['quality'], quality)

    def test_legacy_quality_contract_is_preserved(self):
        for model in ['gpt-image-1.5', 'gpt-image-2', 'gpt-image-2-2026-04-21']:
            with self.subTest(model=model):
                self.assertNotEqual(self.invoke('--model', model, '--quality', 'max').returncode, 0)
        self.assertEqual(self.payload('--model', 'gpt-image-1.5', '--size', '1536x1024')['model'], 'gpt-image-1.5')
        self.assertNotEqual(self.invoke('--model', 'gpt-image-1.5', '--size', '3440x1440').returncode, 0)

    def test_malformed_and_out_of_range_sizes_fail_before_request(self):
        for size in ['null', '', '0x1024', '-1024x1024', '1935x812',
                     '32x32', '4096x2048', '3840x1024', '999999999999x1024']:
            with self.subTest(size=size):
                result = self.invoke('--size', size)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_native_alpha_requires_supported_output_format(self):
        for fmt in ['png', 'webp']:
            payload = self.payload('--background', 'transparent', '--output-format', fmt)
            self.assertEqual(payload['background'], 'transparent')
            self.assertEqual(payload['output_format'], fmt)
        self.assertNotEqual(self.invoke('--background', 'transparent', '--output-format', 'jpeg').returncode, 0)

    def test_batch_validates_each_job_model(self):
        with tempfile.TemporaryDirectory() as workspace:
            jobs = Path(workspace) / 'jobs.jsonl'
            jobs.write_text(json.dumps({'prompt': 'Coral reef', 'model': 'gpt-image-2', 'quality': 'max'}) + '\n')
            result = self.invoke('--input', str(jobs), '--out-dir', str(Path(workspace) / 'output'), command='generate-batch')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('quality', result.stderr)
            self.assertEqual(result.stdout, '')

if __name__ == '__main__':
    unittest.main()
