import json
import pathlib
import tempfile
import unittest

from diagnostics_runtime import check_rss_growth


class RssRegressionTests(unittest.TestCase):
    def check(self, points):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / 'samples.jsonl'
            path.write_text('\n'.join(json.dumps(point) for point in points))
            return check_rss_growth(path, 30, 64)

    def point(self, seconds, mib, run_id=1):
        return dict(elapsed_seconds=seconds, latest=dict(
            run_id=run_id, timestamp=1000 + seconds, rss=mib * 1024 * 1024))

    def test_warmup_growth_does_not_fail_stable_workload(self):
        result = self.check([self.point(0, 10), self.point(30, 100), self.point(40, 101)])
        self.assertTrue(result['passed'])
        self.assertEqual(result['growth_bytes'], 1024 * 1024)

    def test_peak_growth_fails_even_if_last_sample_recovers(self):
        result = self.check([self.point(30, 20), self.point(40, 100), self.point(50, 21)])
        self.assertFalse(result['passed'])

    def test_restart_cannot_hide_growth(self):
        with self.assertRaisesRegex(ValueError, 'restarts'):
            self.check([self.point(30, 100), self.point(40, 20, run_id=2)])

    def test_missing_or_failed_samples_cannot_pass(self):
        for rows in ([self.point(30, 20)], [self.point(30, 20), dict(elapsed_seconds=40, error='timeout')]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.check(rows)

    def test_duplicate_timestamps_cannot_pass(self):
        with self.assertRaisesRegex(ValueError, 'increasing'):
            self.check([self.point(30, 20), self.point(30, 20)])

    def test_invalid_rss_cannot_pass(self):
        for value in (None, -1, float('nan'), float('inf'), True):
            row = self.point(40, 20)
            row['latest']['rss'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.check([self.point(30, 20), row])


if __name__ == '__main__':
    unittest.main()
