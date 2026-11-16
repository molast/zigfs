import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

import capture


class PerfCaptureTests(unittest.TestCase):
    def run_capture(self, events, report_code=0, script_code=0):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        output = pathlib.Path(temporary.name) / 'capture'
        results = [
            subprocess.CompletedProcess([], 0, 'recorded', ''),
            subprocess.CompletedProcess([], report_code, 'report', ''),
            subprocess.CompletedProcess([], script_code, events, ''),
        ]
        with mock.patch.object(capture.os, 'kill'), \
                mock.patch.object(capture.platform, 'system', return_value='Linux'), \
                mock.patch.object(capture.shutil, 'which', return_value='/usr/bin/perf'), \
                mock.patch.object(capture.subprocess, 'run', side_effect=results):
            if report_code or script_code or not events.strip():
                with self.assertRaises(RuntimeError):
                    capture.capture(123, 'cpu', 1, output)
            else:
                capture.capture(123, 'cpu', 1, output)
        return json.loads((output / 'manifest.json').read_text())

    def test_empty_perf_success_is_not_a_profile(self):
        self.assertFalse(self.run_capture('')['passed'])

    def test_report_failure_is_not_a_profile(self):
        self.assertFalse(self.run_capture('cycles:\n', report_code=1)['passed'])

    def test_unreadable_samples_are_not_a_profile(self):
        self.assertFalse(self.run_capture('cycles:\n', script_code=1)['passed'])

    def test_real_samples_are_counted(self):
        result = self.run_capture('cycles:\ncycles:\n')
        self.assertTrue(result['passed'])
        self.assertEqual(result['sample_count'], 2)


if __name__ == '__main__':
    unittest.main()
