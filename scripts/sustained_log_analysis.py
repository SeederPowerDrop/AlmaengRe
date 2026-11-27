#!/usr/bin/env python3
"""Analyze bounded installed-app sustained-test metadata without opening media.

Example:
  python3 scripts/sustained_log_analysis.py --samples RUN/session/samples.jsonl \
    --expected-build 125 --operator-report RUN/operator-report.json \
    --output RUN/analysis.json --require-complete

A missing final report is pending. Incomplete runs, corrupt logs, stale results,
cache/worker limit violations, unverified media outcomes and comparable quiet
memory growth remain findings. Frame publication is not physical screen paint.
Known native VP9 limits require an explicit version-matched probe receipt; they
never count as complete successful rendering. Source names and pixels are not
read. Memory trends are screening evidence rather than proof of a heap leak.
"""

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import statistics
import os
import tempfile

MAX_BYTES = 34 * 1024 * 1024
MAX_LINES = 12002
MIB = 1024 * 1024
PREVIEW_LIMIT = 128 * MIB
EXACT_LIMIT = 384 * MIB
ACTIONS = ("mixedOverview", "fourPhotos", "sixPhotos", "filenameFilter",
           "metadataFilter", "mapSelection", "videoOverview", "fourVideos", "sixVideos",
           "rapidQueries", "comparisonQueries", "audioPlayback")
TILE_COUNTS = {"fourPhotos": 4, "sixPhotos": 6, "fourVideos": 4, "sixVideos": 6}


def reject_constant(value):
    raise ValueError("nonfinite_json_number:" + value)


def finite_float(raw):
    value=float(raw)
    if not math.isfinite(value): raise ValueError('nonfinite_json_number')
    return value


def unique_keys(pairs):
    result = {}
    for key,value in pairs:
        if key in result:
            raise ValueError("duplicate_json_key")
        result[key] = value
    return result


def number(value):
    try:
        return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) else None
    except OverflowError:
        return None


def integer(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def digest(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def load_json(path):
    if not path.exists():
        return None
    data = path.read_bytes()
    if len(data) > MAX_BYTES:
        raise ValueError("json_input_exceeds_bounded_size")
    value = json.loads(data, parse_constant=reject_constant, parse_float=finite_float,object_pairs_hook=unique_keys)
    if not isinstance(value, dict):
        raise ValueError("json_object_required:" + path.name)
    return value


def load_samples(path, final_present):
    # Snapshot one bounded read; a concurrent append can leave one unfinished
    # trailing record. Ignore it only while there is no terminal final report.
    with path.open("rb") as stream:
        data = stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("sample_log_exceeds_bounded_size")
    lines = data.splitlines(keepends=True)
    if len(lines) > MAX_LINES:
        raise ValueError("sample_log_exceeds_bounded_record_count")
    rows, malformed, pending_tail = [], [], False
    for index, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line, parse_constant=reject_constant, parse_float=finite_float,object_pairs_hook=unique_keys)
            if not isinstance(row, dict):
                raise ValueError("record_must_be_object")
            rows.append((index, row))
        except (UnicodeError, ValueError):
            if index == len(lines) and not line.endswith(b"\n") and not final_present:
                pending_tail = True
            else:
                malformed.append(index)
    return rows, malformed, pending_tail, hashlib.sha256(data).hexdigest()


class Evidence:
    def __init__(self):
        self.counts = Counter()
        self.examples = []

    def add(self, category, code, location, **details):
        self.counts[(category, code)] += 1
        if len(self.examples) < 120:
            sanitized = {key: ({"valueSHA256":hashlib.sha256(value.encode()).hexdigest(),"characters":len(value)}
                if isinstance(value,str) and ("/" in value or "\\" in value or len(value)>256) else value)
                for key,value in details.items()}
            self.examples.append(dict(category=category, code=code, location=location, **sanitized))

    def expect(self, row, key, predicate, location, code=None):
        if key not in row:
            self.add("missing", "missing_field", location, field=key)
            return False
        if not predicate(row[key]):
            self.add("failure", code or "invalid_" + key, location, field=key, actual=row[key])
            return False
        return True

    def export(self):
        return {"counts": [dict(category=k[0], code=k[1], count=v)
                           for k, v in sorted(self.counts.items())], "examples": self.examples,
                "exampleLimit": 120, "failureCount": sum(v for (k, _), v in self.counts.items() if k == "failure"),
                "missingEvidenceCount": sum(v for (k, _), v in self.counts.items() if k == "missing"),
                "environmentEvidenceCount":sum(v for (k, _), v in self.counts.items() if k == "environment"),
                "mediaFindingCount":sum(v for (k, _), v in self.counts.items() if k == "media")}


NATIVE_LIMIT_KINDS = {"unsupported", "unreadableData"}
VERSION_FIELDS = ("sourcePathSHA256", "sourceByteCount", "sourceModificationTime",
                  "diagnosticSourceVersionSHA256")
SOURCE_SCOPE = "asset_identity_metadata_not_fresh_stat_or_physical_paint"


def source_version(entry, evidence, location, *, known=False):
    if not isinstance(entry, dict):
        evidence.add("failure", "source_version_object_required", location)
        return None
    path_hash = entry.get("sourcePathSHA256")
    byte_count = integer(entry.get("byteCount" if known else "sourceByteCount"))
    modified = number(entry.get("modificationTime" if known else "sourceModificationTime"))
    if not digest(path_hash) or byte_count is None or byte_count <= 0 or modified is None:
        evidence.add("missing", "source_version_tuple_incomplete", location)
        return None
    if not known and not digest(entry.get("diagnosticSourceVersionSHA256")):
        evidence.add("missing", "diagnostic_source_version_missing", location)
        return None
    if not known and (not isinstance(entry.get("isAudio"), bool)
            or "sourceArchiveIdentitySHA256" not in entry
            or entry["sourceArchiveIdentitySHA256"] is not None
                and not digest(entry["sourceArchiveIdentitySHA256"])
            or entry.get("sourceVersionScope") != SOURCE_SCOPE):
        evidence.add("missing", "source_identity_variant_or_scope_incomplete", location)
        return None
    return path_hash, byte_count, modified


def source_identity(entry, version):
    return (version, entry.get("diagnosticSourceVersionSHA256"), entry.get("isAudio"),
            entry.get("sourceArchiveIdentitySHA256"), entry.get("sourceVersionScope"))


def known_native_limits(receipt, evidence):
    if receipt is None:
        return {}
    location = "known-native-limits"
    valid = True
    for key, predicate in (("schemaVersion", lambda x: integer(x) == 1),
                           ("status", lambda x: x == "completed_native_limit_probe"),
                           ("sourceMetadataUnchanged", lambda x: x is True)):
        valid = evidence.expect(receipt, key, predicate, location) and valid
    entries = receipt.get("entries")
    if not isinstance(entries, list) or not 1 <= len(entries) <= 256:
        evidence.add("failure", "known_native_entries_invalid", location)
        return {}
    limits = {}
    for index, entry in enumerate(entries):
        loc = location + ":" + str(index)
        version = source_version(entry, evidence, loc, known=True)
        if not isinstance(entry, dict):
            valid = False
            continue
        kinds = entry.get("failureKinds")
        proofs = entry.get("nativePlayable") is False and entry.get("posterProbeFailed") is True \
            and entry.get("sourceVersionMatchesBeforeAfter") is True and entry.get("codec") == "vp9" \
            and isinstance(kinds, list) and bool(kinds) and all(isinstance(k, str) and k in NATIVE_LIMIT_KINDS for k in kinds) \
            and len(set(kinds)) == len(kinds)
        if not proofs:
            evidence.add("failure", "known_native_limit_proof_invalid", loc)
            valid = False
        if version is None:
            valid = False
        elif version in limits:
            evidence.add("failure", "known_native_limit_duplicate_version", loc)
            valid = False
        elif proofs:
            limits[version] = set(kinds)
    # A malformed receipt never partially grants exceptions.
    return limits if valid else {}


def index_set(row, key, count, evidence, location):
    values = row.get(key)
    if not isinstance(values, list):
        evidence.add("missing", "slot_index_array_missing", location, field=key)
        return None
    if any(integer(v) is None or not 0 <= v < count for v in values):
        evidence.add("failure", "slot_index_invalid", location, field=key)
        return None
    if len(values) != len(set(values)):
        evidence.add("failure", "slot_index_duplicate", location, field=key)
        return None
    return set(values)


def version_table(row, key, count, evidence, location):
    values = row.get(key)
    if not isinstance(values, list):
        evidence.add("missing", "slot_version_array_missing", location, field=key)
        return None
    result = {}
    for entry in values:
        version = source_version(entry, evidence, location + ":" + key)
        slot = integer(entry.get("slotIndex")) if isinstance(entry, dict) else None
        if slot is None or not 0 <= slot < count or slot in result:
            evidence.add("failure", "slot_version_index_invalid_or_duplicate", location, field=key)
            return None
        if version is None:
            return None
        result[slot] = source_identity(entry, version)
    if set(result) != set(range(count)):
        evidence.add("missing", "slot_version_full_coverage_required", location, field=key)
        return None
    if len(set(v[0][0] for v in result.values())) != count:
        evidence.add("failure", "duplicate_source_identity_in_page", location, field=key)
        return None
    return result


def page_roundtrip(row, count, current, evidence, location):
    initial = version_table(row, "initialPageSlotVersions", count, evidence, location)
    final = version_table(row, "finalPageSlotVersions", count, evidence, location)
    if initial is not None and final is not None and initial != final:
        evidence.add("failure", "page_roundtrip_source_versions_changed", location)
    if current is not None and final is not None and current != final:
        evidence.add("failure", "current_versions_differ_from_roundtrip_final", location)
    for key in ("initialSelectedTargetMatches", "pageIdentityRestored"):
        evidence.expect(row, key, lambda v: v is True, location)
    wanted, selected = integer(row.get("requestedSelectionIndex")), integer(row.get("initialSelectedIndex"))
    start, end = integer(row.get("initialPageStartIndex")), integer(row.get("finalPageStartIndex"))
    if None in (wanted, selected, start, end) or min(wanted, selected, start, end) < 0:
        evidence.add("missing", "page_roundtrip_indices_incomplete", location)
    elif wanted != selected or start != end:
        evidence.add("failure", "page_roundtrip_selection_or_baseline_disagrees", location)
    starts, selections = row.get("observedPageStartIndices"), row.get("observedSelectedIndices")
    if any(not isinstance(v, list) or len(v) != 5 or any(integer(x) is None or x < 0 for x in v)
           for v in (starts, selections)):
        evidence.add("missing", "page_navigation_trace_incomplete", location)
    elif starts[0] != start or starts[-1] != end or selections[0] != selected \
            or selections[-1] != row.get("finalSelectedIndex"):
        evidence.add("failure", "page_navigation_trace_disagrees", location)


def slot_outcomes(row, count, video, evidence, location, limits):
    for key in ("allSlotNativeBackingVerified", "allSlotSettledQualityVerified"):
        evidence.expect(row, key, lambda v: v is False, location,
                        "collector_claims_unproven_all_slot_quality_or_backing")
    current = version_table(row, "currentSlotVersions", count, evidence, location)
    page_roundtrip(row, count, current, evidence, location)
    early = index_set(row, "acceptedCurrentSlotIndices", count, evidence, location)
    early_missing = index_set(row, "unverifiedCurrentSlotIndices", count, evidence, location)
    final = index_set(row, "finalAcceptedCurrentSlotIndices", count, evidence, location)
    unverified = index_set(row, "finalUnverifiedCurrentSlotIndices", count, evidence, location)
    for key, slots in (("acceptedCurrentSlotVersions", early), ("finalAcceptedCurrentSlotVersions", final)):
        evidence.expect(row, key, lambda v, slots=slots: slots is not None and integer(v) == len(slots),
                        location, "slot_count_and_indices_disagree")
    if early is not None and early_missing is not None and early_missing != set(range(count)) - early:
        evidence.add("failure", "early_slot_partition_invalid", location)
    if early is not None and final is not None and not early.issubset(final):
        evidence.add("failure", "early_current_publication_lost_before_final_snapshot", location)
    evidence.expect(row, "earlyObservationRequestedSeconds", lambda v: number(v) == 2, location)
    evidence.expect(row, "earlyObservationSeconds", lambda v: number(v) is not None and v >= 2,
                    location, "early_observation_clock_invalid")
    evidence.expect(row, "finalSettleLimitSeconds", lambda v: number(v) == 15, location)
    evidence.expect(row, "finalSettleSeconds", lambda v: number(v) is not None and 0 <= v <= 15,
                    location, "final_settle_outside_configured_bound")
    evidence.expect(row, "finalSettleTimedOut", lambda v: v is False, location, "final_settle_timed_out")
    terminal_values = row.get("terminalCurrentSlots")
    terminals, expected_limits = {}, []
    if not isinstance(terminal_values, list):
        evidence.add("missing", "terminal_slot_array_missing", location)
        terminal_values = []
    for entry in terminal_values:
        version = source_version(entry, evidence, location + ":terminal")
        slot = integer(entry.get("slotIndex")) if isinstance(entry, dict) else None
        if slot is None or not 0 <= slot < count or slot in terminals:
            evidence.add("failure", "terminal_slot_index_invalid_or_duplicate", location)
            continue
        terminals[slot] = entry
        matches = current is not None and version is not None and current.get(slot) == \
            source_identity(entry, version) and entry.get("sourceVersionMatchesCurrent") is True
        if not matches:
            evidence.add("failure", "terminal_source_version_does_not_match_current", location, slot=slot)
            continue
        if not isinstance(entry.get("errorDomain"), str) or not entry["errorDomain"] \
                or integer(entry.get("errorCode")) is None:
            evidence.add("missing", "terminal_native_error_metadata_missing", location, slot=slot)
            continue
        failure = entry.get("failureKind")
        if video and entry.get("isAudio") is False and entry.get("sourceArchiveIdentitySHA256") is None \
                and isinstance(failure, str) and failure in NATIVE_LIMIT_KINDS and failure in limits.get(version, set()):
            expected_limits.append(slot)
        else:
            evidence.add("media", "terminal_failure_not_proven_expected_native_format_limit", location,
                         slot=slot, failureKind=failure)
    terminal_set = set(terminals)
    if final is not None and terminal_set & final:
        evidence.add("failure", "accepted_terminal_overlap", location)
    remaining = set(range(count)) - ((final or set()) | terminal_set)
    if unverified is not None and unverified != remaining:
        evidence.add("failure", "final_slot_partition_invalid", location)
    if remaining:
        evidence.add("missing", "final_current_slots_without_outcome", location, slots=sorted(remaining))
    declared = row.get("unsupportedCurrentSlots")
    if not isinstance(declared, list):
        evidence.add("missing", "typed_unsupported_subset_missing", location)
    else:
        declared_slots = set()
        for entry in declared:
            slot = integer(entry.get("slotIndex")) if isinstance(entry, dict) else None
            if slot in declared_slots or slot not in terminals or entry != terminals.get(slot) \
                    or entry.get("failureKind") != "unsupported":
                evidence.add("failure", "typed_unsupported_subset_invalid", location)
            declared_slots.add(slot)
        if declared_slots != {s for s, v in terminals.items() if v.get("failureKind") == "unsupported"}:
            evidence.add("failure", "typed_unsupported_subset_incomplete", location)
    return {"earlyAcceptedCurrentTileCount": len(early) if early is not None else None,
            "earlyObservationScope": "two_seconds_publication_speed_snapshot_not_final_acceptance",
            "earlyObservationRequestedSeconds": row.get("earlyObservationRequestedSeconds"),
            "earlyObservationActualSeconds": row.get("earlyObservationSeconds"),
            "finalAcceptedCurrentTileCount": len(final) if final is not None else None,
            "terminalCurrentTileCount": len(terminals), "expectedNativeFormatLimitIndices": sorted(expected_limits),
            "unverifiedFinalTileIndices": sorted(remaining), "fullRenderingAccepted": final == set(range(count))
                and not terminals and current is not None,
            "finalSettleSeconds": row.get("finalSettleSeconds"),
            "nativeBackingOrSettledPixelQualityVerified": False,
            "outcome": "expected_native_format_limit_separate_from_rendering" if expected_limits
                else "all_current_versions_accepted" if final == set(range(count)) and not terminals
                else "current_slot_outcomes_not_accepted"}


def analyze_actions(rows, evidence, final_present, limits):
    action_rows = [(line, row) for line, row in rows if row.get("kind") == "action"]
    resource_rows = [(line, row) for line, row in rows if row.get("kind") == "resource"]
    counts = Counter(row.get("action") for _, row in action_rows if isinstance(row.get("action"), str))
    completed_counts=Counter(row.get('action') for _,row in action_rows if row.get('status')=='completed')
    environment_failures=sum(isinstance(row.get('failure'),str) and row['failure'].startswith('environment_') for _,row in action_rows)
    results, expected_native_limits = [], 0
    for line, row in action_rows:
        name, location = row.get("action"), "samples.jsonl:" + str(line)
        if not isinstance(name, str):
            name = None
        result = {"line": line, "action": name, "cycle": row.get("cycle"), "recordedStatus": row.get("status"),
                  "elapsedSeconds": row.get("elapsedSeconds")}
        end = number(row.get("elapsedSeconds"))
        nearby = [(n, r) for n, r in resource_rows if end is not None and number(r.get("elapsedSeconds")) is not None
                  and 0 <= end - r["elapsedSeconds"] <= 3 and r.get("phase") == name
                  and r.get("phaseAfterSnapshot") == name and r.get("phaseChangedDuringSnapshot") is False]
        if nearby:
            resource_line, resource = max(nearby, key=lambda item: item[1]["elapsedSeconds"])
            result["nearestPriorStableResourceObservation"] = dict(line=resource_line,
                secondsBeforeActionEnd=end - resource["elapsedSeconds"],
                **{k: resource.get(k) for k in ("ownForeground", "windowVisibleAndUnoccluded",
                   "runningOperations", "queuedOperations", "cacheBudgetsValid")})
        environmental=isinstance(row.get('failure'),str) and row['failure'].startswith('environment_')
        if environmental:
            evidence.add('environment','scenario_condition_unavailable',location,action=name,reason=row['failure'])
        else:
            evidence.expect(row, "status", lambda x: x == "completed", location, "action_not_completed")
            evidence.expect(row, "failure", lambda x: x == "", location, "action_failure_recorded")
        if name not in ACTIONS:
            evidence.add("failure", "unknown_action", location, action=name)
        if name in TILE_COUNTS:
            expected = TILE_COUNTS[name]
            video = name.endswith("Videos")
            evidence.expect(row, "actualVisibleCount", lambda x: integer(x) == expected, location)
            evidence.expect(row, "pageInputs", lambda x: integer(x) == 4, location)
            evidence.expect(row, "pageIdentityRestored", lambda x: x is True, location)
            policy = "quality" if expected == 4 else "responsive"
            evidence.expect(row, "loadingPolicy", lambda x: x == policy, location)
            evidence.expect(row, "media", lambda x: x == ("video_posters" if video else "photos"), location)
            result.update(expectedTileCount=expected)
            result.update(slot_outcomes(row, expected, video, evidence, location, limits))
            expected_native_limits += len(result["expectedNativeFormatLimitIndices"])
            if video:
                evidence.expect(row, "explicitVideoPlayingCount", lambda x: integer(x) == 0,
                                location, "video_started_playing")
                evidence.expect(row, "audioOwnerPresent", lambda x: x is False, location, "audio_owner_present")
                result["silentAndPausedAtRecordedObservation"] = integer(row.get("explicitVideoPlayingCount")) == 0 \
                    and row.get("audioOwnerPresent") is False
        if name in ("rapidQueries","comparisonQueries"):
            evidence.expect(row,"latestResultMatches",lambda x:x is True,location,"stale_query_result")
            evidence.expect(row,"inputChanges",lambda x:integer(x) is not None and x >= 20,location)
        if name == "audioPlayback" and not environmental:
            for key in ("clockAdvanced","oldItemReleased","muted"):
                evidence.expect(row,key,lambda x:x is True,location,"audio_playback_or_release_unverified")
            evidence.expect(row,"clockAdvanceSeconds",lambda x:number(x) is not None and x>0.05,location)
        results.append(result)
    for action in ACTIONS:
        if counts[action] == 0 and final_present:
            evidence.add("missing", "required_action_not_observed", "actions", action=action)
    return {"recordCount": len(action_rows), "counts": {k: counts[k] for k in ACTIONS},
            "completedCounts":{k:completed_counts[k] for k in ACTIONS},
            "environmentalActionFailures":environment_failures,
            "unobservedRequiredActions": [k for k in ACTIONS if counts[k] == 0],
            "expectedNativeFormatLimitTileObservations": expected_native_limits,
            "earlyCountsAreNotFinalCounts": True,
            "unsupportedScopeTextAloneNeverCountsAsEvidence": True, "records": results}


def analyze_resources(rows, evidence):
    resources = [(line, row) for line, row in rows if row.get("kind") == "resource"]
    previous_elapsed, previous_cpu = None, None
    footprints, residents, cpus, intervals = [], [], [], []
    pairs = (("renderedBitmapRAMBytes", "renderedBitmapRAMLimit"), ("thumbnailRAMBytes", "thumbnailRAMLimit"),
             ("diskBytes", "diskLimit"), ("diskPreviewBytes", "previewDiskByteLimit"),
             ("diskExactBytes", "exactDiskByteLimit"))
    for line, row in resources:
        location = "samples.jsonl:" + str(line)
        for key in ("ownForeground", "windowVisibleAndUnoccluded"):
            if row.get(key) is False:
                evidence.add('environment','foreground_or_visibility_unavailable',location,field=key)
            else:
                evidence.expect(row, key, lambda x: x is True, location,
                                "actual_foreground_or_visibility_condition_not_satisfied")
        for key in ("queuedOperations", "runningOperations", "queryRunningOperations", "queryQueuedOperations", "queryWaiters"):
            evidence.expect(row, key, lambda x: integer(x) is not None and x >= 0,
                            location, "operation_counter_invalid")
        limit = integer(row.get("queryConcurrencyLimit"))
        running = integer(row.get("queryRunningOperations"))
        if limit not in (1,2) or running is not None and running > limit:
            evidence.add("failure","query_concurrency_limit_invalid_or_exceeded",location)
        for key in ("diskSnapshotAvailable", "diskAccountingComplete"):
            if row.get(key) is not True:
                evidence.add("missing", "disk_usage_unverified", location, field=key, actual=row.get(key))
        for key in ("cacheBudgetsValid", "diskTierBudgetsValid"):
            evidence.expect(row, key, lambda x: x is True, location, "reported_cache_validation_failure")
        for used_key, limit_key in pairs:
            used, limit = integer(row.get(used_key)), integer(row.get(limit_key))
            if used is None or limit is None:
                evidence.add("missing", "cache_byte_counter_missing", location, usedField=used_key, limitField=limit_key)
            elif used < 0 or limit < 0 or used > limit:
                evidence.add("failure", "cache_byte_budget_exceeded_or_invalid", location,
                             usedField=used_key, used=used, limit=limit)
        for key, ceiling in (("previewDiskByteLimit", PREVIEW_LIMIT), ("exactDiskByteLimit", EXACT_LIMIT),
                             ("diskLimit", PREVIEW_LIMIT + EXACT_LIMIT), ("thumbnailRAMLimit", 64 * MIB)):
            limit = integer(row.get(key))
            if limit is not None and limit > ceiling:
                evidence.add("failure", "cache_budget_larger_than_production_default", location, field=key, limit=limit)
        elapsed, cpu = number(row.get("elapsedSeconds")), number(row.get("processCPUSecondsSinceStart"))
        interval = number(row.get("sampleIntervalSeconds"))
        if elapsed is None or cpu is None or interval is None or min(elapsed, cpu, interval) < 0:
            evidence.add("missing", "resource_clock_or_CPU_counter_invalid", location)
        else:
            if previous_elapsed is not None and elapsed < previous_elapsed:
                evidence.add("failure", "resource_clock_regressed", location)
            if previous_elapsed is not None and abs(elapsed - previous_elapsed - interval) > max(.001, interval * .001):
                evidence.add("missing", "resource_interval_does_not_match_elapsed_gap", location)
            if previous_cpu is not None and cpu < previous_cpu - .000001:
                evidence.add("failure", "resource_CPU_counter_regressed", location)
            previous_elapsed, previous_cpu = elapsed, cpu
            intervals.append(interval)
            if interval >= .25 and number(row.get("intervalCPUPercentOneCore")) is not None:
                cpus.append(row["intervalCPUPercentOneCore"])
        for key, target in (("footprintBytes", footprints), ("residentBytes", residents)):
            value = integer(row.get(key))
            if value is None or value < 0:
                evidence.add("missing", "process_memory_counter_missing", location, field=key)
            else:
                target.append(value)
    return {"recordCount": len(resources), "ownForegroundRecords": sum(r.get("ownForeground") is True for _, r in resources),
            "visibleAndUnoccludedRecords": sum(r.get("windowVisibleAndUnoccluded") is True for _, r in resources),
            "sampledPeakFootprintBytes": max(footprints, default=None), "sampledPeakRSSBytes": max(residents, default=None),
            "sampledMaximumCPUPercentOneCoreExcludingIntervalsBelowQuarterSecond": max(cpus, default=None),
            "sampleIntervalMaximumSeconds": max(intervals, default=None),
            "sampleIntervalsAboveThreeSeconds": sum(x > 3 for x in intervals),
            "memoryPressureNotificationSeen": any(r.get("memoryPressureObserved") is True for _, r in resources),
            "realLowPowerModeObserved": any(r.get("lowPowerMode") is True for _, r in resources),
            "fullSessionAwakeOrForegroundContinuityProven": False}


def analyze_quiet(rows, evidence):
    resources = [r for _, r in rows if r.get("kind") == "resource"]
    checkpoints, comparable = [], 0
    seen_indices, previous_end = set(), None
    for line, row in rows:
        if row.get("kind") != "checkpoint":
            continue
        location = "samples.jsonl:" + str(line)
        evidence.expect(row, "status", lambda x: x == "observed", location, "checkpoint_failed")
        end, wall = number(row.get("elapsedSeconds")), number(row.get("quietWallSeconds"))
        start = end - wall if end is not None and wall is not None else None
        duration_valid = wall is not None and wall >= 30
        if not duration_valid:
            evidence.add("failure", "quiet_duration_less_than_thirty_seconds_or_invalid", location)
        index = integer(row.get("index"))
        if index is None or index < 0 or index in seen_indices:
            evidence.add("failure", "quiet_checkpoint_index_invalid_or_duplicate", location)
        else:
            seen_indices.add(index)
        if previous_end is not None and start is not None and start < previous_end:
            evidence.add("failure", "quiet_checkpoint_windows_overlap_or_regress", location)
        if end is not None:
            previous_end = end
        phase = "reference_quiet_" + str(row.get("index"))
        samples = [r for r in resources if start is not None and number(r.get("elapsedSeconds")) is not None
                   and number(r.get("sampleIntervalSeconds")) is not None
                   and r["elapsedSeconds"] - r["sampleIntervalSeconds"] >= start and r["elapsedSeconds"] <= end
                   and r.get("phase") == phase and r.get("phaseAfterSnapshot") == phase
                   and r.get("phaseChangedDuringSnapshot") is False]
        verified = bool(samples) and all(r.get("referencePresented") is True and r.get("referenceGeometryMatches") is True
            and r.get("ownForeground") is True and r.get("windowVisibleAndUnoccluded") is True
            and integer(r.get("queuedOperations")) == 0 and integer(r.get("runningOperations")) == 0
            and integer(r.get("queryRunningOperations")) == 0 and integer(r.get("queryQueuedOperations")) == 0
            and r.get("cacheBudgetsValid") is True and r.get("diskAccountingComplete") is True for r in samples)
        # Whole stable sampling intervals must cover nearly the entire window.
        # At most one observed interval can straddle each edge; an interval
        # exceeding3seconds is too sparse for this quiet-floor receipt.
        sample_intervals = [number(r.get("sampleIntervalSeconds")) for r in samples]
        maximum_interval = max(sample_intervals, default=0)
        coverage = sum(sample_intervals)
        enough_coverage = duration_valid and len(samples) >= 3 and 0 < maximum_interval <= 3 \
            and coverage >= wall - 2 * maximum_interval
        eligible = row.get("comparableReferenceQuiet") is True and row.get("quietBudgetsValid") is True \
            and verified and enough_coverage
        background_verified=bool(samples) and all(r.get('ownForeground') is False
            and r.get('referencePresented') is True and r.get('referenceGeometryMatches') is True
            and r.get('windowVisibleAndUnoccluded') is True and r.get('cacheBudgetsValid') is True
            and r.get('diskAccountingComplete') is True and integer(r.get('queuedOperations'))==0
            and integer(r.get('runningOperations'))==0 and integer(r.get('queryRunningOperations'))==0
            and integer(r.get('queryQueuedOperations'))==0 for r in samples)
        comparable += int(eligible)
        footprint = [r["footprintBytes"] for r in samples if integer(r.get("footprintBytes")) is not None]
        resident = [r["residentBytes"] for r in samples if integer(r.get("residentBytes")) is not None]
        # Recompute using Python integers. Embedded median fields may contain an
        # incorrect UInt64->Double bit-pattern conversion and are not trusted.
        checkpoints.append({"index": row.get("index"), "line": line, "wholeQuietResourceSamples": len(samples),
            "quietWallSeconds": wall, "stableResourceIntervalCoverageSeconds": coverage,
            "maximumStableResourceIntervalSeconds": maximum_interval,
            "sufficientWholeWindowResourceCoverage": enough_coverage,
            "eligibleComparableQuiet": eligible,
            "eligibleComparableBackgroundQuiet":background_verified and enough_coverage,
            "footprintMedianBytesRecomputed": statistics.median(footprint) if footprint else None,
            "RSSMedianBytesRecomputed": statistics.median(resident) if resident else None,
            "embeddedMediansUsedForAcceptance": False})
    return {"checkpointCount": len(checkpoints), "verifiedComparableCount": comparable, "records": checkpoints}


def analyze_trends(rows, quiet, warmup_seconds=600, growth_bytes=64*MIB, slope_bytes_per_minute=2*MIB, background=False):
    checkpoints = {line:row for line,row in rows if row.get('kind')=='checkpoint'}
    floors=[]
    for q in quiet['records']:
        row=checkpoints.get(q['line'],{})
        elapsed=number(row.get('elapsedSeconds'))
        memory=number(q.get('footprintMedianBytesRecomputed'))
        eligible=q.get('eligibleComparableBackgroundQuiet') if background else q['eligibleComparableQuiet']
        if eligible and elapsed is not None and elapsed>=warmup_seconds and memory is not None:
            floors.append(dict(elapsedSeconds=elapsed,footprintBytes=memory,
                quietCPUPercentOneCore=number(row.get('quietAverageCPUPercentOneCore'))))
    floors.sort(key=lambda row:row['elapsedSeconds'])
    slopes=[(b['footprintBytes']-a['footprintBytes'])/((b['elapsedSeconds']-a['elapsedSeconds'])/60)
        for index,a in enumerate(floors) for b in floors[index+1:] if b['elapsedSeconds']>a['elapsedSeconds']]
    slope=statistics.median(slopes) if slopes else None
    delta=floors[-1]['footprintBytes']-floors[0]['footprintBytes'] if len(floors)>=2 else None
    upward=sum(b['footprintBytes']>a['footprintBytes'] for a,b in zip(floors,floors[1:]))
    enough=len({row['elapsedSeconds'] for row in floors})>=3
    suspected=bool(enough and delta>=growth_bytes and slope>=slope_bytes_per_minute and upward>=2)
    hot_idle=sum(row['quietCPUPercentOneCore'] is not None and row['quietCPUPercentOneCore']>10 for row in floors)>=3
    return dict(status='suspected_sustained_growth' if suspected else 'no_threshold_crossing_observed' if enough else 'insufficient_comparable_post_warmup_checkpoints',
        condition='background' if background else 'foreground',
        warmupSeconds=warmup_seconds,eligiblePostWarmupCheckpoints=floors,
        memoryDeltaBytes=delta,medianPairwiseSlopeBytesPerMinute=slope,
        growthThresholdBytes=growth_bytes,slopeThresholdBytesPerMinute=slope_bytes_per_minute,
        suspectedMemoryGrowth=suspected,idleCPUAboveTenPercentInThreeWindows=hot_idle,
        leakProof=False,scope='same verified reference and geometry, drained decode/query queues; footprint includes OS/framework caches, not a heap-leak proof')


def action_timings(rows):
    result={}
    for action in ACTIONS:
        records=[row for _,row in rows if row.get('kind')=='action' and row.get('action')==action and row.get('status')=='completed']
        metrics={}
        for key in ('wallSeconds','processCPUSeconds','lastInputToCommitSeconds','querySeconds'):
            values=sorted(row[key] for row in records if number(row.get(key)) is not None and row[key]>=0)
            if values:
                metrics[key]=dict(samples=len(values),median=statistics.median(values),
                    p95=values[max(0,math.ceil(len(values)*0.95)-1)],maximum=max(values))
        result[action]=dict(completed=len(records),metrics=metrics)
    return dict(actions=result,scope='successful instrumented phases; includes warmup, programmed holds and debounce; phase wall time is not frame paint latency')


def analyze(rows, malformed, pending_tail, sample_digest, report, progress, expected_build,
            native_limit_receipt=None, operator=None):
    evidence = Evidence()
    terminal = report is not None
    for line in malformed:
        evidence.add("failure", "malformed_sample_record", "samples.jsonl:" + str(line))
    starts = [r for _, r in rows if r.get("kind") == "start"]
    if len(starts) != 1:
        evidence.add("missing", "single_start_record_required", "samples.jsonl", count=len(starts))
    start = starts[0] if starts else {}
    if start:
        evidence.expect(start, "build", lambda x: str(x) == expected_build, "start", "unexpected_build")
        evidence.expect(start, "sourcePathsExported", lambda x: x is False, "start")
        evidence.expect(start, "sourcePixelsExported", lambda x: x is False, "start")
    limits = known_native_limits(native_limit_receipt, evidence)
    actions = analyze_actions(rows, evidence, terminal, limits)
    resources = analyze_resources(rows, evidence)
    quiet = analyze_quiet(rows, evidence)
    trends = analyze_trends(rows,quiet)
    background_trends=analyze_trends(rows,quiet,background=True)
    if trends['suspectedMemoryGrowth'] or background_trends['suspectedMemoryGrowth']:
        evidence.add('failure','suspected_sustained_memory_growth','quiet-checkpoints')
    if trends['idleCPUAboveTenPercentInThreeWindows'] or background_trends['idleCPUAboveTenPercentInThreeWindows']:
        evidence.add('failure','sustained_idle_CPU_elevated','quiet-checkpoints')
    if operator is not None:
        for key,predicate in (("status",lambda x:x=='observation_finished'),
            ("build",lambda x:x==expected_build),("privateContextVerified",lambda x:x is True),
            ("sourceMetadataUnchanged",lambda x:x is True),("executableUnchanged",lambda x:x is True),
            ("reason",lambda x:x==''),("processID",lambda x:integer(x)==integer(start.get('processID'))),
            ("wallSeconds",lambda x:number(x) is not None and x>=operator.get('requestedSeconds',float('inf')))):
            evidence.expect(operator,key,predicate,'operator-report.json')
        restoration=operator.get('restoration',{})
        if not isinstance(restoration,dict): restoration={}
        for key in ('workUnchangedDuringRun','workRestored','windowValuesRestored'):
            evidence.expect(restoration,key,lambda x:x is True,'operator-report.json')
    if terminal:
        for key, predicate in (
            ("status", lambda x: x == "completed_observation"), ("stopReason", lambda x: x == ""),
            ("minimumThirtyMinutesActuallyObserved", lambda x: x is True),
            ("requestedDurationSeconds", lambda x: number(x) is not None and 1800 <= x <= 7200
             and x == start.get("durationSeconds")),
            ("observedWallSeconds", lambda x: number(x) is not None and x >= 1800),
            ("allScenarioChecksPassed", lambda x: x is True),
            ("cacheBudgetViolations", lambda x: integer(x) == 0), ("actionFailureCount", lambda x: integer(x) == 0),
            ("sourceMetadataUnchanged", lambda x: x is True), ("normalWorkSettingsUnchanged", lambda x: x is True),
            ("normalUserPreferencesUnchanged", lambda x: x is True),
            ("sourcePathsExported", lambda x: x is False), ("sourcePixelsExported", lambda x: x is False)):
            if actions['environmentalActionFailures'] and key in ('status','allScenarioChecksPassed','actionFailureCount'):
                evidence.add('environment','scenario_completion_includes_environment_gaps','sustained-report.json',field=key)
            else:
                evidence.expect(report, key, predicate, "sustained-report.json")
        if number(report.get("observedWallSeconds")) is not None and number(report.get("requestedDurationSeconds")) is not None \
            and report["observedWallSeconds"] < report["requestedDurationSeconds"]:
            evidence.add("failure", "requested_duration_not_finished", "sustained-report.json")
        for key, count in (("actionCount", actions["recordCount"]), ("resourceSampleCount", resources["recordCount"])):
            evidence.expect(report, key, lambda x, count=count: integer(x) == count,
                            "sustained-report.json", "report_and_sample_counts_disagree")
        before, after = report.get("sourceBeforeDigest"), report.get("sourceAfterDigest")
        if not digest(before) or before != after or before != start.get("sourceInventoryDigest"):
            evidence.add("failure", "source_inventory_digests_missing_or_disagree", "sustained-report.json")
        evidence.expect(report, "sourceFileCount", lambda x: integer(x) is not None and x > 0
                        and x == start.get("sourceFiles"), "sustained-report.json", "source_inventory_counts_disagree")
        if resources["recordCount"] == 0:
            evidence.add("missing", "resource_samples_required", "samples.jsonl")
        if quiet["verifiedComparableCount"] < 2:
            evidence.add("missing", "two_verified_comparable_quiet_checkpoints_required", "checkpoints")
        reported_counts = report.get("actionCounts")
        if not isinstance(reported_counts, dict) or any(reported_counts.get(k,0) != v for k, v in actions["completedCounts"].items()):
            evidence.add("failure", "reported_action_counts_disagree", "sustained-report.json")
    findings = evidence.export()
    expected_limits = actions["expectedNativeFormatLimitTileObservations"]
    receipts_complete = terminal and not findings["failureCount"] and not findings["missingEvidenceCount"] \
        and not findings['environmentEvidenceCount'] and not findings['mediaFindingCount']
    accepted = receipts_complete and not expected_limits
    if not terminal:
        status = 'interrupted_without_final_report' if operator and operator.get('status')=='interrupted_or_failed' \
            else "in_progress_with_observed_failures" if findings["failureCount"] \
            else 'in_progress_with_environment_or_media_findings' if findings['environmentEvidenceCount'] or findings['mediaFindingCount'] \
            else "pending_final_report"
    elif findings["failureCount"]:
        status = "rejected_observed_validation_failure"
    elif findings['mediaFindingCount']:
        status='completed_with_media_findings'
    elif findings['environmentEvidenceCount']:
        status='inconclusive_environment_conditions'
    elif findings["missingEvidenceCount"]:
        status = "inconclusive_missing_evidence"
    elif expected_limits:
        status = "completed_with_expected_native_format_limits_not_full_rendering"
    else:
        status = "accepted_instrumented_checks"
    return {"schemaVersion": 2, "status": status, "strictAccepted": accepted,
        "instrumentedReceiptsCompleteIncludingExpectedNativeLimits": receipts_complete,
        "fullRenderingAccepted": accepted,
        "expectedNativeLimitVersionCount": len(limits),
        "diagnosticSHAIsOpaqueComparedNotRecomputed": True,
        "finalReportPresent": terminal, "pendingAppendTailIgnored": pending_tail,
        "sampleLogSnapshotSHA256": sample_digest, "sampleLogRecordCount": len(rows),
        "expectedBuild": expected_build, "recordedBuild": start.get("build"),
        "progressStatusAtRead": progress.get("status") if progress else None,
        "progressElapsedSecondsAtRead": progress.get("elapsedSeconds") if progress else None,
        "actions": actions, "resources": resources, "quietCheckpoints": quiet, "findings": findings,
        "trends":trends,"backgroundTrends":background_trends,"actionTimings":action_timings(rows),"operatorReceiptPresent":operator is not None,
        "excludedPreferenceCategories": {key: report.get(key) if report else None for key in (
            "normalWindowPreferenceValuesUnchangedDuringObservation", "normalVolatileHomeQuotePreferencesUnchangedDuringObservation")},
        "scope": "existing_record_metadata_only_no_product_code_import_app_control_photo_or_manifest_access",
        "performanceAcceptanceOrLeakProof": False,
        "limitations": [
            "A pending report is never accepted; run again after the atomic final report is written.",
            "Accepted slot versions prove recorded publication, not physical paint or final quality of every image.",
            "Two-second accepted counts are speed observations; final15-second bounded outcomes are separate.",
            "Only current source-version-joined native VP9 probe limits may be separately acknowledged; other terminal failures reject.",
            "Expected native limits never become full successful rendering, precise native backing or settled pixel quality.",
            "Comparable quiet floors require at least30seconds and stable whole sampling intervals covering the window, with at most one interval per edge and no interval above3seconds.",
            "Process CPU/footprint/RSS exclude separate Quick Look services, system GPU occupancy and energy.",
            "Resource samples can miss shorter peaks; OS file/native caches were not cleared.",
            "A source metadata digest is membership/size/mtime evidence, not a content checksum.",
            "Work preferences exclude window geometry and volatile home quote; those require separate operator verification.",
            "No whole-session awake/foreground or performance budget is inferred from elapsed time alone."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--progress", type=Path)
    parser.add_argument("--expected-build", required=True)
    parser.add_argument("--known-native-limits", type=Path,
                        help="explicit immutable native VP9 probe receipt; exact source-version joins only")
    parser.add_argument("--operator-report",type=Path,help="launcher identity, original-source and normal-preference restoration receipt")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-complete", action="store_true",
                        help="exit 0 only for strictAccepted; exit 1 for observed failures, 2 for pending/gaps")
    args = parser.parse_args()
    report_path = args.report or args.samples.with_name("sustained-report.json")
    progress_path = args.progress or args.samples.with_name("progress.json")
    inputs = [args.samples, report_path, progress_path]
    if args.known_native_limits:
        inputs.append(args.known_native_limits)
    if args.operator_report:
        inputs.append(args.operator_report)
    if args.output.resolve() in {p.resolve() for p in inputs}:
        parser.error("output must not overwrite an input")
    if args.output.exists():
        try:
            owned=(load_json(args.output) or {}).get('analysisKind')=='almeng_sustained_log_analysis'
        except (OSError,ValueError,TypeError,RecursionError):
            owned=False
        if not owned:
            parser.error('refusing_to_overwrite_unowned_output')
    try:
        report, progress = load_json(report_path), load_json(progress_path)
        rows, malformed, tail, sha = load_samples(args.samples, report is not None)
        native_limits = load_json(args.known_native_limits) if args.known_native_limits else None
        if args.known_native_limits and native_limits is None:
            raise ValueError("requested_known_native_limits_file_missing")
        operator=load_json(args.operator_report) if args.operator_report else None
        if args.operator_report and operator is None:
            raise ValueError('operator_receipt_missing')
        result = analyze(rows, malformed, tail, sha, report, progress, args.expected_build, native_limits,operator)
        result["knownNativeLimitsReceiptSHA256"] = hashlib.sha256(args.known_native_limits.read_bytes()).hexdigest() \
            if args.known_native_limits else None
        encoded = json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    except (OSError, ValueError, TypeError, OverflowError, RecursionError,AttributeError,KeyError,IndexError) as error:
        result = {"schemaVersion": 1, "status": "input_unavailable_or_invalid", "strictAccepted": False,
                  "error": str(error), "performanceAcceptanceOrLeakProof": False}
        encoded = json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    result['analysisKind']='almeng_sustained_log_analysis'
    encoded=json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False)+'\n'
    with tempfile.NamedTemporaryFile(mode='w',dir=args.output.parent,prefix='.'+args.output.name+'.',delete=False) as stream:
        stream.write(encoded); temporary=stream.name
    os.replace(temporary,args.output)
    print(json.dumps({key: result.get(key) for key in ("status", "strictAccepted", "finalReportPresent")}, ensure_ascii=False))
    if args.require_complete and not result["strictAccepted"]:
        raise SystemExit(1 if result.get("findings", {}).get("failureCount", 0) or result.get('findings',{}).get('mediaFindingCount',0) else 2)


if __name__ == "__main__":
    main()
