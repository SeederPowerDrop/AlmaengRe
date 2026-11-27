import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
def module(name):
    spec = importlib.util.spec_from_file_location(name,SCRIPTS/(name+'.py'))
    value=importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value
runner=module('sustained_test_runner')
analysis=module('sustained_log_analysis')


class RunnerTests(unittest.TestCase):
    def test_disjoint_check_uses_filesystem_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); source=root/'Source'; source.mkdir()
            link=root/'Alias'; link.symlink_to(source,target_is_directory=True)
            self.assertTrue(runner.physically_below(link/'new-output',source))
            self.assertFalse(runner.physically_below(root/'elsewhere',source))
    def test_crash_summary_joins_pid_and_build_without_exporting_image_paths(self):
        value=dict(pid=7,bundleInfo={'CFBundleVersion':'125'},exception={'type':'EXC_BREAKPOINT','signal':'SIGTRAP'},
            termination={'namespace':'SIGNAL','code':5},faultingThread=0,
            usedImages=[dict(name='ImageViewer',path='/private/personal-location/app')],
            threads=[dict(frames=[dict(imageIndex=0,symbol='pressure callback'),
                                  dict(imageIndex=0,symbol='/private/personal-photo.dng')])])
        result=runner.summarize_crash(value,7,'125')
        self.assertNotIn('/private/',json.dumps(result))
        self.assertEqual(result['signal'],'SIGTRAP')
        self.assertIsNone(runner.summarize_crash(value,8,'125'))
        self.assertIsNone(runner.summarize_crash(value,7,'124'))
    def test_source_receipt_is_read_only_and_contains_no_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); photo=root/'private-personal-name.dng'
            photo.write_bytes(b'RAW test bytes')
            before=photo.stat()
            receipt=runner.source_inventory(root)
            self.assertEqual(photo.stat().st_mtime_ns,before.st_mtime_ns)
            self.assertNotIn('private-personal-name',json.dumps(receipt))
            photo.write_bytes(b'changed')
            self.assertNotEqual(receipt,runner.source_inventory(root))

    def test_invalid_output_cannot_touch_source_or_launch_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); source=root/'source'; source.mkdir()
            args=mock.Mock(source=source,output=source/'bad-output',app=root/'missing.app')
            with mock.patch.object(runner.subprocess,'run') as launch:
                with self.assertRaises(ValueError): runner.run(args)
                launch.assert_not_called()
            self.assertEqual(list(source.iterdir()),[])

    def test_watchdog_does_not_treat_process_liveness_as_progress(self):
        def reason(**kw):
            values=dict(progress={'elapsedSeconds':1},last_elapsed=1,last_change=0,now=20,
                        process_alive=True,deadline=1000,log_sizes=[10],stale_seconds=120)
            values.update(kw); return runner.watchdog_reason(**values)
        self.assertIsNone(reason())
        self.assertEqual(reason(now=121),'heartbeat_stalled')
        self.assertEqual(reason(process_alive=False),'process_exited_without_final_report')
        self.assertEqual(reason(now=1001),'overall_deadline')
        self.assertEqual(reason(log_sizes=[runner.MAX_CAPTURE_BYTES+1]),'framework_log_limit')

    def test_partial_and_nonfinite_progress_are_not_valid_objects(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'progress.json'
            self.assertIsNone(runner.read_object(path))
            for content in ['{"elapsed":NaN}','{"elapsed":1e9999}','[]','{"elapsed":']:
                path.write_text(content)
                with self.assertRaises(ValueError): runner.read_object(path)
            runner.atomic_json(path,{'status':'running'})
            self.assertEqual(runner.read_object(path),{'status':'running'})


class EvidenceTests(unittest.TestCase):
    def test_phase_timing_excludes_failed_and_nonfinite_samples(self):
        rows=[(1,dict(kind='action',action='rapidQueries',status='completed',wallSeconds=1,lastInputToCommitSeconds=.1)),
              (2,dict(kind='action',action='rapidQueries',status='completed',wallSeconds=3,lastInputToCommitSeconds=.3)),
              (3,dict(kind='action',action='rapidQueries',status='failed',wallSeconds=100))]
        result=analysis.action_timings(rows)['actions']['rapidQueries']
        self.assertEqual(result['completed'],2)
        self.assertEqual(result['metrics']['wallSeconds']['median'],2)
        self.assertEqual(result['metrics']['lastInputToCommitSeconds']['p95'],.3)

    def test_complete_synthetic_receipts_can_pass_and_a_stale_result_cannot(self):
        # Synthetic schema fixture, never reported as an actual timed run.
        source='b'*64
        rows=[dict(kind='start',build='125',processID=7,durationSeconds=1800,
            sourceInventoryDigest=source,sourceFiles=20,sourcePathsExported=False,sourcePixelsExported=False)]
        for elapsed in range(1,1831):
            phase='reference_quiet_0' if elapsed<=30 else 'reference_quiet_1' if elapsed>1800 else 'working'
            rows.append(dict(kind='resource',elapsedSeconds=elapsed,sampleIntervalSeconds=1,
                processCPUSecondsSinceStart=elapsed/1000,intervalCPUPercentOneCore=0.1,
                ownForeground=True,windowVisibleAndUnoccluded=True,queuedOperations=0,runningOperations=0,
                queryQueuedOperations=0,queryRunningOperations=0,queryWaiters=0,queryConcurrencyLimit=2,
                diskSnapshotAvailable=True,diskAccountingComplete=True,cacheBudgetsValid=True,diskTierBudgetsValid=True,
                renderedBitmapRAMBytes=0,renderedBitmapRAMLimit=256*analysis.MIB,thumbnailRAMBytes=0,
                thumbnailRAMLimit=64*analysis.MIB,diskBytes=0,diskLimit=512*analysis.MIB,diskPreviewBytes=0,
                previewDiskByteLimit=128*analysis.MIB,diskExactBytes=0,exactDiskByteLimit=384*analysis.MIB,
                footprintBytes=500*analysis.MIB,residentBytes=500*analysis.MIB,
                referencePresented=True,referenceGeometryMatches=True,phase=phase,phaseAfterSnapshot=phase,phaseChangedDuringSnapshot=False))
        for index,action in enumerate(analysis.ACTIONS):
            row=dict(kind='action',action=action,status='completed',failure='',elapsedSeconds=100+index)
            if action in analysis.TILE_COUNTS:
                count=analysis.TILE_COUNTS[action]
                versions=[dict(slotIndex=i,sourcePathSHA256=f'{i+1:064x}',sourceByteCount=10,sourceModificationTime=100,
                    diagnosticSourceVersionSHA256=f'{i+101:064x}',sourceArchiveIdentitySHA256=None,isAudio=False,
                    sourceVersionScope=analysis.SOURCE_SCOPE) for i in range(count)]
                row.update(actualVisibleCount=count,pageInputs=4,pageIdentityRestored=True,
                    loadingPolicy='quality' if count==4 else 'responsive',media='video_posters' if action.endswith('Videos') else 'photos',
                    allSlotNativeBackingVerified=False,allSlotSettledQualityVerified=False,
                    currentSlotVersions=versions,initialPageSlotVersions=versions,finalPageSlotVersions=versions,
                    requestedSelectionIndex=0,initialSelectedTargetMatches=True,initialSelectedIndex=0,initialPageStartIndex=0,
                    finalSelectedIndex=0,finalPageStartIndex=0,observedPageStartIndices=[0,count,count*2,count,0],
                    observedSelectedIndices=[0,count,count*2,count,0],acceptedCurrentSlotIndices=list(range(count)),
                    unverifiedCurrentSlotIndices=[],finalAcceptedCurrentSlotIndices=list(range(count)),finalUnverifiedCurrentSlotIndices=[],
                    acceptedCurrentSlotVersions=count,finalAcceptedCurrentSlotVersions=count,earlyObservationRequestedSeconds=2,
                    earlyObservationSeconds=2,finalSettleLimitSeconds=15,finalSettleSeconds=1,finalSettleTimedOut=False,
                    terminalCurrentSlots=[],unsupportedCurrentSlots=[],explicitVideoPlayingCount=0,audioOwnerPresent=False)
            if action in ('rapidQueries','comparisonQueries'): row.update(inputChanges=34,latestResultMatches=True)
            if action=='audioPlayback': row.update(clockAdvanced=True,oldItemReleased=True,muted=True,clockAdvanceSeconds=0.7)
            rows.append(row)
        for index,end in [(0,30),(1,1830)]:
            rows.append(dict(kind='checkpoint',index=index,elapsedSeconds=end,quietWallSeconds=30,status='observed',
                             comparableReferenceQuiet=True,quietBudgetsValid=True,quietAverageCPUPercentOneCore=0.1))
        rows.sort(key=lambda row:row.get('elapsedSeconds',0))
        numbered=list(enumerate(rows,1))
        report=dict(status='completed_observation',requestedDurationSeconds=1800,observedWallSeconds=1830,
            stopReason='',minimumThirtyMinutesActuallyObserved=True,
            allScenarioChecksPassed=True,cacheBudgetViolations=0,actionFailureCount=0,sourceMetadataUnchanged=True,
            normalWorkSettingsUnchanged=True,normalUserPreferencesUnchanged=True,sourcePathsExported=False,
            sourcePixelsExported=False,actionCount=len(analysis.ACTIONS),resourceSampleCount=1830,
            sourceBeforeDigest=source,sourceAfterDigest=source,sourceFileCount=20,actionCounts={k:1 for k in analysis.ACTIONS})
        result=analysis.analyze(numbered,[],False,'0'*64,report,{},'125')
        self.assertTrue(result['strictAccepted'],result['findings'])
        next(row for row in rows if row.get('action')=='rapidQueries')['latestResultMatches']=False
        result=analysis.analyze(numbered,[],False,'0'*64,report,{},'125')
        self.assertFalse(result['strictAccepted'])

    def test_background_quiet_floors_are_never_mixed_with_foreground(self):
        rows=[(i,dict(kind='checkpoint',elapsedSeconds=t,quietAverageCPUPercentOneCore=0.2))
              for i,t in enumerate([600,900,1200])]
        quiet=dict(records=[dict(line=i,eligibleComparableQuiet=False,eligibleComparableBackgroundQuiet=True,
            footprintMedianBytesRecomputed=500*1024*1024) for i in range(3)])
        foreground=analysis.analyze_trends(rows,quiet)
        background=analysis.analyze_trends(rows,quiet,background=True)
        self.assertEqual(foreground['status'],'insufficient_comparable_post_warmup_checkpoints')
        self.assertEqual(background['status'],'no_threshold_crossing_observed')
        self.assertEqual(background['condition'],'background')

    def test_background_audio_gap_is_not_reported_as_a_stale_result_bug(self):
        evidence=analysis.Evidence()
        rows=[(1,dict(kind='action',action='audioPlayback',status='failed',
                     failure='environment_not_foreground_for_audio',elapsedSeconds=10))]
        result=analysis.analyze_actions(rows,evidence,False,{})
        self.assertEqual(result['completedCounts']['audioPlayback'],0)
        self.assertEqual(evidence.export()['failureCount'],0)
        self.assertGreater(evidence.export()['environmentEvidenceCount'],0)

    def test_duplicate_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'samples.jsonl'
            path.write_text('{"status":"failed","status":"completed"}\n')
            _,malformed,_,_=analysis.load_samples(path,False)
            self.assertEqual(malformed,[1])

    def test_analyzer_cannot_overwrite_an_existing_unowned_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'original.bin'; path.write_bytes(b'original media bytes')
            sample=Path(directory)/'samples.jsonl'; sample.write_text('')
            result=subprocess.run([sys.executable,str(SCRIPTS/'sustained_log_analysis.py'),
                '--samples',str(sample),'--expected-build','125','--output',str(path)],capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(path.read_bytes(),b'original media bytes')

    def test_invalid_new_input_replaces_an_old_accepted_analysis_with_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/'analysis.json'
            output.write_text(json.dumps(dict(analysisKind='almeng_sustained_log_analysis',strictAccepted=True)))
            sample=Path(directory)/'samples.jsonl'; sample.write_text('{bad json}\n')
            result=subprocess.run([sys.executable,str(SCRIPTS/'sustained_log_analysis.py'),
                '--samples',str(sample),'--expected-build','125','--output',str(output),'--require-complete'],capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(json.loads(output.read_text())['strictAccepted'])

    def test_memory_growth_requires_comparable_post_warmup_windows(self):
        def trend(values):
            rows=[(i,dict(kind='checkpoint',elapsedSeconds=t,quietAverageCPUPercentOneCore=0.2)) for i,(t,_) in enumerate(values)]
            quiet=dict(records=[dict(line=i,eligibleComparableQuiet=True,footprintMedianBytesRecomputed=mb*1024*1024)
                                for i,(_,mb) in enumerate(values)])
            return analysis.analyze_trends(rows,quiet)
        self.assertFalse(trend([(10,20),(300,400),(600,500),(900,502),(1200,498)])['suspectedMemoryGrowth'])
        self.assertTrue(trend([(600,500),(900,550),(1200,600)])['suspectedMemoryGrowth'])
        self.assertFalse(trend([(600,500),(900,800)])['suspectedMemoryGrowth'])
        self.assertEqual(trend([(600,500),(600,550),(600,600)])['status'],'insufficient_comparable_post_warmup_checkpoints')

    def test_pending_append_tail_is_tolerated_only_without_final_report(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'samples.jsonl'
            path.write_bytes(b'{"kind":"resource"}\n{"kind":')
            rows,malformed,pending,_=analysis.load_samples(path,False)
            self.assertEqual(len(rows),1); self.assertFalse(malformed); self.assertTrue(pending)
            _,malformed,pending,_=analysis.load_samples(path,True)
            self.assertEqual(malformed,[2]); self.assertFalse(pending)

    def test_missing_final_or_malformed_records_never_pass(self):
        result=analysis.analyze([],[],False,'0'*64,None,None,'124')
        self.assertFalse(result['strictAccepted'])
        self.assertEqual(result['status'],'pending_final_report')
        result=analysis.analyze([], [1],False,'0'*64,{},None,'124')
        self.assertFalse(result['strictAccepted'])
        self.assertGreater(result['findings']['failureCount'],0)


if __name__=='__main__': unittest.main()
