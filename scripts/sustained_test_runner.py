#!/usr/bin/env python3
"""Run the installed app's isolated 30–120 minute multimedia diagnostic.

  python3 scripts/sustained_test_runner.py --source /path/to/media \
    --output /path/to/new-run --minutes 30

Requires macOS/Xcode command line tools. The app is normally closed/reopened;
its work preferences are preserved. Output must be outside the source folder.
No schedule or background service is installed. Exit 0 requires strict final
evidence, not merely a living process or elapsed time. Framework logs and the
preference rollback snapshot are private; structured reports contain hashes.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import sys
import time

SCRIPT_DIR = Path(__file__).resolve().parent
MAX_CAPTURE_BYTES = 8 * 1024 * 1024


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def source_inventory(source):
    entries = []
    for path in source.iterdir():
        s = path.lstat()
        if stat.S_ISREG(s.st_mode):
            entries.append(dict(pathSHA256=hashlib.sha256(str(path).encode()).hexdigest(),
                                bytes=s.st_size, mtimeNs=s.st_mtime_ns))
        if len(entries) > 200_000:
            raise ValueError('source_inventory_limit')
    return sorted(entries, key=lambda x: x['pathSHA256'])


def physically_below(path, directory):
    # APFS may be case/Unicode insensitive even when path strings differ.
    return any(p.exists() and os.path.samefile(p,directory) for p in [path,*path.parents])


def read_object(path):
    if not path.exists():
        return None
    if path.stat().st_size > 34 * 1024 * 1024:
        raise ValueError('bounded_json_limit')
    def finite(raw):
        value=float(raw)
        if not math.isfinite(value): raise ValueError('nonfinite_json')
        return value
    value = json.loads(path.read_text(),parse_float=finite,parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite_json')))
    if not isinstance(value, dict):
        raise ValueError('json_object_required')
    return value


def watchdog_reason(progress, last_elapsed, last_change, now, process_alive,
                    deadline, log_sizes, stale_seconds):
    if not process_alive:
        return 'process_exited_without_final_report'
    if any(size > MAX_CAPTURE_BYTES for size in log_sizes):
        return 'framework_log_limit'
    if now > deadline:
        return 'overall_deadline'
    if now-last_change > stale_seconds:
        return 'heartbeat_stalled'
    return None


def summarize_crash(value, pid, build):
    if value.get('pid') != pid or str(value.get('bundleInfo',{}).get('CFBundleVersion')) != str(build):
        return None
    images=value.get('usedImages',[])
    threads=value.get('threads',[])
    index=value.get('faultingThread')
    frames=threads[index].get('frames',[]) if isinstance(index,int) and 0<=index<len(threads) else []
    summary=[]
    for frame in frames[:20]:
        image_index=frame.get('imageIndex',-1)
        name=images[image_index].get('name','unknown') if isinstance(image_index,int) and 0<=image_index<len(images) else 'unknown'
        symbol=frame.get('symbol','unsymbolicated')
        # Paths, register state, exception messages and loaded-image paths stay
        # in macOS's private original report, not in this structured summary.
        if not isinstance(symbol,str) or '/' in symbol or '\\' in symbol: symbol='redacted_symbol'
        if not isinstance(name,str) or '/' in name: name='redacted_module'
        summary.append(dict(module=name[:80],symbol=symbol[:300]))
    return dict(processID=pid,build=str(build),exceptionType=value.get('exception',{}).get('type'),
                signal=value.get('exception',{}).get('signal'),
                terminationNamespace=value.get('termination',{}).get('namespace'),
                terminationCode=value.get('termination',{}).get('code'),frames=summary,
                sourcePathsExported=False,scope='matching PID and app build; selected stack symbols only')


def find_crash(pid, build, directory=None):
    directory=directory or Path.home()/'Library/Logs/DiagnosticReports'
    try:
        files=sorted(directory.glob('ImageViewer-*.ips'),key=lambda p:p.stat().st_mtime,reverse=True)[:32]
    except OSError:
        return None
    for path in files:
        try:
            if path.stat().st_size > 4*1024*1024: continue
            raw=path.read_text()
            value=json.loads(raw.split('\n',1)[1])
            summary=summarize_crash(value,pid,build)
            if summary: return summary
        except (OSError,ValueError,TypeError,KeyError,IndexError,AttributeError,RecursionError):
            continue
    return None


def run(args):
    source, output, app = args.source.resolve(), args.output.resolve(), args.app.resolve()
    if not source.is_dir() or output == source or output.is_relative_to(source) or source.is_relative_to(output) \
            or physically_below(output,source):
        raise ValueError('disjoint_existing_source_and_new_output_required')
    if output.exists() or not output.parent.is_dir():
        raise ValueError('new_output_with_existing_parent_required')
    if not app.is_relative_to(Path('/Applications')):
        raise ValueError('installed_app_in_Applications_required')
    os.umask(0o077)
    output.mkdir(mode=0o700)
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'org.openimageviewer.ImageViewer':
        raise ValueError('unexpected_app_identity')
    executable = app/'Contents/MacOS/ImageViewer'
    binary_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)], check=True, capture_output=True)
    host = output/'qa-host'
    subprocess.run(['xcrun','swiftc','-swift-version','6',str(SCRIPT_DIR/'sustained-qa-host.swift'),'-o',str(host)],
                   check=True, capture_output=True)

    def native(command, *values):
        result = subprocess.run([str(host),command,str(app),*[str(v) for v in values]],
                                text=True, capture_output=True, timeout=25)
        if result.returncode:
            raise RuntimeError('native_host_'+command+'_failed')
        return json.loads(result.stdout)

    def status():
        return native('status')

    initial = status()
    if initial['frontmostBundleID'] == 'com.apple.loginwindow':
        raise RuntimeError('foreground_environment_locked')
    previous = initial['applications']
    if any(not p['matchesApp'] for p in previous):
        raise RuntimeError('another_bundle_with_same_identifier')
    session = output/'session'  # The app itself creates this exclusively.
    snapshot = output/'normal-preferences.plist'
    receipt = dict(schemaVersion=1, status='starting', build=str(info['CFBundleVersion']),
                   runnerProcessID=os.getpid(), requireForeground=args.require_foreground,
                   foregroundReactivations=0,
                   version=info['CFBundleShortVersionString'], executableSHA256=binary_hash,
                   requestedSeconds=args.minutes*60, originalAppWasRunning=bool(previous),
                   sourceDirectorySHA256=hashlib.sha256(str(source).encode()).hexdigest(),
                   structuredSourcePathsExported=False, rawFrameworkLogsPrivate=True)
    qa = None
    awake = None
    reason = ''
    prefs = None
    source_before = None
    source_unchanged = False
    restoration = {}
    started = time.monotonic()
    try:
        for p in previous:
            native('quit', p['pid'], p['launchTime'])
        prefs = native('capture',snapshot)
        source_before = source_inventory(source)
        atomic_json(output/'source-before.json',dict(entries=source_before))
        env = dict(IMAGEVIEWER_MANUAL_QA='1', IMAGEVIEWER_SUSTAINED_QA='1',
                   IMAGEVIEWER_SUSTAINED_SECONDS=str(args.minutes*60), IMAGEVIEWER_SUSTAINED_AUDIO_FIXTURE='1',
                   IMAGEVIEWER_MANUAL_QA_SOURCE=str(source), IMAGEVIEWER_MANUAL_QA_OUTPUT=str(session))
        command = ['open','-n']
        for key,value in env.items():
            command += ['--env',key+'='+value]
        command += ['--stdout',str(output/'framework-stdout.log'),'--stderr',str(output/'framework-stderr.log'),
                    str(app),'--args','-ApplePersistenceIgnoreState','YES']
        subprocess.run(command,check=True,capture_output=True)
        launch_deadline = time.monotonic()+25
        while time.monotonic() < launch_deadline:
            processes = status()['applications']
            if len(processes) == 1 and processes[0]['matchesApp']:
                qa = processes[0]
                break
            time.sleep(0.2)
        if qa is None:
            raise RuntimeError('private_app_launch_failed')
        receipt.update(status='running',processID=qa['pid'],launchTime=qa['launchTime'],preferences=prefs)
        atomic_json(output/'launch.json',receipt)
        native('activate',qa['pid'],qa['launchTime'])
        activation_deadline=time.monotonic()+10
        while time.monotonic()<activation_deadline:
            if any(p['pid']==qa['pid'] and p['active'] for p in status()['applications']): break
            time.sleep(0.2)
        else:
            raise RuntimeError('foreground_activation_failed')
        awake = subprocess.Popen(['caffeinate','-d','-i','-w',str(qa['pid'])],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        last_elapsed = -1
        last_change = time.monotonic()
        last_print = 0
        inactive_since=None
        final = session/'sustained-report.json'
        deadline = time.monotonic()+args.minutes*60+360
        while not final.exists():
            now = time.monotonic()
            current = status()
            matching = [p for p in current['applications'] if p['pid']==qa['pid'] and p['launchTime']==qa['launchTime']]
            if (output/'stop-request.json').exists():
                raise RuntimeError('operator_stop_requested')
            if args.require_foreground:
                if matching and matching[0]['active']:
                    inactive_since=None
                elif inactive_since is None:
                    inactive_since=now
                    if args.maintain_foreground:
                        native('activate',qa['pid'],qa['launchTime'])
                        receipt['foregroundReactivations']+=1
                elif now-inactive_since>30:
                    raise RuntimeError('required_foreground_condition_interrupted')
            if len(current['applications']) > 1:
                raise RuntimeError('concurrent_app_instance')
            progress = read_object(session/'progress.json')
            context = read_object(session/'manual-qa-context.json')
            if context and context.get('status') in {'marks_not_ready','open_not_ready','audio_fixture_failed','invalid_sustained_duration','sustained_failed'}:
                raise RuntimeError('startup_'+context['status'])
            elapsed = progress.get('elapsedSeconds',-1) if progress else -1
            if isinstance(elapsed,(int,float)) and not isinstance(elapsed,bool) and elapsed > last_elapsed:
                last_elapsed, last_change = elapsed, now
            sizes = [p.stat().st_size for p in [output/'framework-stdout.log',output/'framework-stderr.log'] if p.exists()]
            failure = watchdog_reason(progress,last_elapsed,last_change,now,bool(matching),deadline,sizes,args.watchdog_seconds)
            if failure:
                raise RuntimeError(failure)
            if now-last_print >= 30:
                print(json.dumps(dict(kind='progress',elapsedSeconds=max(0,last_elapsed),
                    phase=progress.get('phase','startup') if progress else 'startup',
                    actions=progress.get('actionCount',0) if progress else 0,
                    failures=progress.get('actionFailureCount',0) if progress else 0)),flush=True)
                last_print=now
            time.sleep(2)
        context = read_object(session/'manual-qa-context.json')
        receipt['privateContextVerified'] = bool(context and context.get('processID')==qa['pid']
            and context.get('defaultsSuiteName','').startswith('ImageViewer.ManualQA.'))
        if not receipt['privateContextVerified']:
            raise RuntimeError('private_context_identity_missing')
        result = read_object(final)
        if time.monotonic()-started < args.minutes*60 or result.get('observedWallSeconds',0) < args.minutes*60:
            raise RuntimeError('real_observation_duration_incomplete')
        receipt['status']='observation_finished'
    except (OSError,ValueError,RuntimeError,subprocess.SubprocessError,KeyboardInterrupt) as error:
        reason = type(error).__name__ if not isinstance(error,RuntimeError) else str(error)
        receipt.update(status='interrupted_or_failed',reason=reason)
    finally:
        if qa is not None:
            try:
                current = status()['applications']
                target = next((p for p in current if p['pid']==qa['pid'] and p['launchTime']==qa['launchTime'] and p['matchesApp']),None)
                if target:
                    try:
                        native('quit',target['pid'],target['launchTime'])
                    except (RuntimeError,subprocess.SubprocessError):
                        # Only this run's exact PID and launch time may be killed.
                        live = next((p for p in status()['applications'] if p['pid']==qa['pid'] and p['launchTime']==qa['launchTime'] and p['matchesApp']),None)
                        if live:
                            os.kill(qa['pid'],signal.SIGKILL)
                            receipt['ownedDiagnosticForceStopped']=True
                            reason = reason or 'owned_diagnostic_would_not_quit'
                            time.sleep(1)
            except (OSError,RuntimeError,subprocess.SubprocessError):
                reason = reason or 'diagnostic_cleanup_failed'
        if awake is not None:
            try:
                awake.terminate()
                awake.wait(timeout=5)
            except (OSError,subprocess.SubprocessError):
                reason = reason or 'awake_assertion_cleanup_failed'
        if source_before is not None:
            try:
                source_unchanged=source_inventory(source)==source_before
            except OSError:
                source_unchanged=False
        try:
            if prefs is not None and not status()['applications']:
                restoration=native('restore',snapshot)
                context=read_object(session/'manual-qa-context.json')
                if context and qa and context.get('processID')==qa['pid']:
                    native('clean-private',context['defaultsSuiteName'])
        except (OSError,ValueError,RuntimeError,subprocess.SubprocessError):
            reason=reason or 'normal_preferences_restore_failed'
        unchanged_binary = hashlib.sha256(executable.read_bytes()).hexdigest()==binary_hash
        if not unchanged_binary:
            reason=reason or 'installed_executable_changed_during_run'
        receipt.update(wallSeconds=time.monotonic()-started,sourceMetadataUnchanged=source_unchanged,
                       executableUnchanged=unchanged_binary,
                       restoration=restoration,reason=reason)
        if qa and reason=='process_exited_without_final_report':
            receipt['crashSummary']=find_crash(qa['pid'],receipt['build'])
        if reason:
            receipt['status']='interrupted_or_failed'
        atomic_json(output/'launch.json',receipt)
        if previous and not status()['applications']:
            restore_command=['open'] + ([] if any(p['active'] for p in previous) else ['-g']) + [str(app)]
            subprocess.run(restore_command,check=True,capture_output=True)
        if not args.keep_runtime and (session/'runtime').is_dir():
            try:
                shutil.rmtree(session/'runtime')
            except OSError:
                receipt['runtimeCleanupFailed']=True
                reason=reason or 'private_runtime_cleanup_failed'
        receipt['reason']=reason
        atomic_json(output/'operator-report.json',receipt)

    analyzed = subprocess.run([sys.executable,str(SCRIPT_DIR/'sustained_log_analysis.py'),
        '--samples',str(session/'samples.jsonl'),'--expected-build',receipt['build'],
        '--operator-report',str(output/'operator-report.json'),
        '--output',str(output/'analysis.json'),'--require-complete'],capture_output=True,text=True)
    print(analyzed.stdout.strip(),flush=True)
    analysis=read_object(output/'analysis.json') or {}
    report=read_object(session/'sustained-report.json') or {}
    atomic_json(output/'summary.json',dict(status=analysis.get('status','analysis_unavailable'),
        strictAccepted=analysis.get('strictAccepted',False),requestedSeconds=args.minutes*60,
        observedSeconds=report.get('observedWallSeconds'),actions=report.get('actionCount'),
        findings=analysis.get('findings',{}).get('counts',[]),
        foregroundMemoryTrend=analysis.get('trends'),backgroundMemoryTrend=analysis.get('backgroundTrends'),
        normalSettingsRestored=restoration.get('workRestored',False),sourceMetadataUnchanged=source_unchanged,
        processCPUPercentOneCore=report.get('averageCPUPercentOneCore'),
        note='Inspection of this run only; not proof of absence of leaks, GPU/FPS/energy or every format support'))
    return analyzed.returncode if not reason and source_unchanged and restoration.get('workRestored') else 1


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--app',type=Path,default=Path('/Applications/알맹Re.app'))
    parser.add_argument('--minutes',type=int,default=30,choices=range(30,121),metavar='30..120')
    parser.add_argument('--watchdog-seconds',type=int,default=120)
    parser.add_argument('--keep-runtime',action='store_true',help='Preserve the bounded private caches for diagnosis')
    parser.add_argument('--require-foreground',action='store_true',help='Stop with an environment finding if focus is lost for over 30 seconds')
    parser.add_argument('--maintain-foreground',action='store_true',help='Explicitly re-request real app activation after focus loss; all gaps stay in the log')
    args=parser.parse_args()
    if args.watchdog_seconds < 30 or args.watchdog_seconds > 300:
        parser.error('watchdog must be 30..300 seconds')
    if args.maintain_foreground and not args.require_foreground:
        parser.error('--maintain-foreground requires --require-foreground')
    try:
        return run(args)
    except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as error:
        print(json.dumps(dict(status='setup_failed',error=type(error).__name__)),flush=True)
        return 2


if __name__=='__main__':
    sys.exit(main())
