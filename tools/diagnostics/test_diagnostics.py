import json
import pathlib
import tempfile
import unittest
from unittest import mock

import dump
import report
import snapshot
import stress
import symbolize


class DiagnosticTests(unittest.TestCase):
    def test_snapshot_comparison_rejects_restarts_and_missing_samples(self):
        a={'telemetry':{'latest':{'run_id':1,'timestamp':10,'heap':100}}}
        b={'telemetry':{'latest':{'run_id':2,'timestamp':20,'heap':200}}}
        self.assertFalse(snapshot.compare(a,b)['comparable'])
        self.assertFalse(snapshot.compare({},a)['comparable'])
        b['telemetry']['latest']['run_id']=1
        self.assertEqual(snapshot.compare(a,b)['deltas']['heap'],100)

    def test_invalid_comparison_file_cannot_leave_snapshot_passed(self):
        with tempfile.TemporaryDirectory() as temp:
            root=pathlib.Path(temp);binary=root/'binary';binary.write_bytes(b'test')
            before=root/'before.json';before.write_text('{invalid json')
            with mock.patch.object(snapshot,'verify_process'),mock.patch.object(snapshot.platform,'system',return_value='Darwin'),mock.patch.object(snapshot.shutil,'which',return_value='/usr/bin/vmmap'),mock.patch.object(snapshot,'execute',return_value={'exit_code':0}):
                result=snapshot.run(42,binary,root/'out',previous=before)
            self.assertFalse(result['passed']);self.assertIn('error',result)

    def test_wrong_binary_hash_rejected_before_symbolizer_or_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root=pathlib.Path(temp)
            binary=root/'binary';binary.write_bytes(b'changed-binary')
            output=root/'out'
            with self.assertRaisesRegex(ValueError,'SHA-256'):
                symbolize.run(binary,output,addresses=[123],expected_hash='wrong')
            self.assertFalse(output.exists())

    def test_report_missing_or_failed_evidence_cannot_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            root=pathlib.Path(temp)
            source=root/'snapshot.json';source.write_text(json.dumps({'kind':'memory-snapshot','passed':True}))
            combined=report.build([source],root/'missing',required={'dump','memory-snapshot'})
            self.assertFalse(combined['passed']);self.assertEqual(combined['missing'],['dump'])
            source.write_text(json.dumps({'kind':'memory-snapshot','passed':False}))
            combined=report.build([source],root/'failed',required={'memory-snapshot'})
            self.assertFalse(combined['passed'])

    def test_resource_summary_does_not_compare_across_restart(self):
        with tempfile.TemporaryDirectory() as temp:
            path=pathlib.Path(temp)/'samples.jsonl'
            path.write_text('\n'.join(json.dumps({'latest':{'run_id':run,'timestamp':stamp,'heap':heap}}) for run,stamp,heap in [(1,1,100),(2,2,20)]))
            value=report.resource_summary(path)
            self.assertFalse(value['comparable']);self.assertIsNone(value['gauges']['heap']['delta'])

    def test_stress_detects_content_corruption_and_cleans_namespace(self):
        stored={};calls=[]
        class Client:
            def __init__(self,target):pass
            def request(self,method,path,body=b''):
                calls.append((method,path))
                if method=='PUT': stored[path]=body
                if method=='GET': return b'corrupt'
                if method=='DELETE': stored.pop(path,None)
                return b''
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(stress.benchmark,'S3',Client):
            value=stress.run({},pathlib.Path(temp)/'run',seconds=1,concurrency=2,size=16,pause=.02)
            self.assertFalse(value['passed']);self.assertGreater(value['errors']['payload_mismatch'],0)
            self.assertEqual(value['cleanup_errors'],[]);self.assertEqual(stored,{})
            self.assertEqual(calls[-1][0],'DELETE');self.assertEqual(calls[-1][1].count('/'),1)

    def test_stress_success_requires_real_observations_and_duration(self):
        stored={}
        class Client:
            def __init__(self,target):pass
            def request(self,method,path,body=b''):
                if method=='PUT':stored[path]=body
                if method=='GET':return stored[path]
                if method=='DELETE':stored.pop(path,None)
                return b''
        with tempfile.TemporaryDirectory() as temp,mock.patch.object(stress.benchmark,'S3',Client):
            value=stress.run({},pathlib.Path(temp)/'run',seconds=1,concurrency=1,size=16,pause=.02)
            self.assertTrue(value['passed']);self.assertGreaterEqual(value['elapsed_seconds'],1)
            self.assertEqual(stored,{})

    def test_failed_core_is_not_left_as_a_valid_memory_artifact(self):
        with tempfile.TemporaryDirectory() as temp:
            root=pathlib.Path(temp);binary=root/'binary';binary.write_bytes(b'test')
            output=root/'out'
            def failed_capture(*args,**kwargs):
                (output/'capture.json').write_text(json.dumps({'passed':False,'error':'File too large'}))
                (output/'process.core').write_bytes(b'partial-core')
                return {'exit_code':0,'timed_out':False,'log':'debugger.log'}
            with mock.patch.object(dump.shutil,'which',return_value='/tool/lldb'),mock.patch.object(dump,'execute',side_effect=failed_capture):
                result=dump.run(binary,output)
            self.assertFalse(result['passed']);self.assertFalse((output/'process.core').exists())
            self.assertEqual(result['capture']['discarded_partial_bytes'],len(b'partial-core'))

    def test_histogram_overflow_and_no_samples_are_unavailable(self):
        self.assertIsNone(stress.percentile([0]*14,0,.99))
        self.assertIsNone(stress.percentile([0]*13+[1],1,.99))
        self.assertEqual(stress.percentile([0,3]+[0]*12,3,.99),5)


if __name__=='__main__':unittest.main()
