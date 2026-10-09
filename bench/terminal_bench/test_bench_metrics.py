#!/usr/bin/env python3
"""Bench metrics tests (issue #1392 AC2/AC8/AC9).

Run: python3 -m unittest discover -s bench/terminal_bench
Covers: FA_CONN line parsing (the Dart ConnTrace wire), per-trial
bench_metrics.json shape, live-progress line format contract, latency
percentiles, session inter-record gaps, and the score-honesty cross-check.
"""
import json
import sys
import unittest
from io import StringIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import bench_metrics
import fa_agent_timeout


class ParseConnEventsTest(unittest.TestCase):
    def test_parses_prefixed_json_lines_and_skips_noise(self):
        text = "\n".join(
            [
                "some pane noise",
                'FA_CONN {"event":"request_start","seq":1,"method":"POST",'
                '"url":"https://x/v1","fresh":null}',
                "",
                'FA_CONN {"event":"first_byte","seq":1,"wallSec":213.0,"slow":true,'
                '"fresh":true,"localPort":54321,"poolSize":2,"connAgeSec":912.0}',
                "FA_CONN not-json-at-all",
                'FA_CONN {"event":"retry","attempt":1,"delaySec":2.0,'
                '"reason":"connect stall: no response bytes"}',
            ]
        )
        events = bench_metrics.parse_conn_events(text)
        self.assertEqual([e["event"] for e in events],
                         ["request_start", "first_byte", "retry"])
        self.assertEqual(events[1]["localPort"], 54321)

    def test_empty_and_none_input(self):
        self.assertEqual(bench_metrics.parse_conn_events(""), [])
        self.assertEqual(bench_metrics.parse_conn_events(None), [])


class PercentileTest(unittest.TestCase):
    def test_nearest_rank_percentiles(self):
        values = [1.0, 2.0, 3.0, 4.0, 5.0]
        self.assertEqual(bench_metrics.percentile(values, 50), 3.0)
        self.assertEqual(bench_metrics.percentile(values, 95), 5.0)
        self.assertEqual(bench_metrics.percentile(values, 0), 1.0)
        self.assertEqual(bench_metrics.percentile(values, 100), 5.0)

    def test_empty_values(self):
        self.assertIsNone(bench_metrics.percentile([], 95))


class SummarizeTrialTest(unittest.TestCase):
    def test_bench_metrics_shape(self):
        events = [
            {"event": "request_start", "seq": 1, "method": "POST",
             "url": "https://x/v1", "fresh": None},
            {"event": "first_byte", "seq": 1, "wallSec": 10.0, "slow": False,
             "fresh": True, "localPort": 100, "poolSize": 1, "connAgeSec": 0.0},
            {"event": "request_done", "seq": 1, "statusCode": 200},
            {"event": "first_byte", "seq": 2, "wallSec": 20.0, "slow": False,
             "fresh": False, "localPort": 100, "poolSize": 1, "connAgeSec": 30.0},
            {"event": "request_done", "seq": 2, "statusCode": 200},
        ]
        metrics = bench_metrics.summarize_trial(
            "train-fasttext", events, concurrency_level=2
        )
        self.assertEqual(metrics["trial"], "train-fasttext")
        self.assertEqual(metrics["concurrency_level"], 2)
        self.assertEqual(len(metrics["requests"]), 2)
        req = metrics["requests"][0]
        self.assertEqual(req["seq"], 1)
        self.assertEqual(req["first_byte_sec"], 10.0)
        self.assertTrue(req["fresh"])
        latency = metrics["latency"]["first_byte"]
        self.assertEqual(latency["p50"], 10.0)
        self.assertEqual(latency["p95"], 20.0)
        self.assertEqual(latency["max"], 20.0)
        self.assertEqual(latency["n"], 2)
        self.assertEqual(metrics["latency"]["reused_requests"], 1)
        self.assertEqual(metrics["latency"]["fresh_requests"], 1)
        self.assertEqual(metrics["watchdog_events"], [])

    def test_watchdog_and_stale_events_collected(self):
        events = [
            {"event": "idle_watchdog_fired", "idleSec": 300.0,
             "connAgeSec": 912.0, "localPort": 54321},
            {"event": "connect_watchdog_fired", "timeoutSec": 120.0,
             "attempt": 0},
            {"event": "stale_socket", "localPort": 54321, "ageSec": 912.0,
             "error": "connection reset"},
            {"event": "retry", "attempt": 1, "delaySec": 2.0, "reason": "r"},
        ]
        metrics = bench_metrics.summarize_trial("t", events)
        # retry rides the watchdog list too: a retry IS a watchdog outcome.
        self.assertEqual(len(metrics["watchdog_events"]), 4)
        self.assertEqual(metrics["watchdog_events"][0]["event"],
                         "idle_watchdog_fired")
        self.assertEqual(metrics["latency"]["first_byte"], None)
        self.assertEqual(metrics["requests"], [])

    def test_connect_failed_events_are_not_dropped(self):
        # Round-3 review: connect_failed (origin-aware stale attribution,
        # AC9) must fold into watchdog_events — dropping it blinds the
        # discrimination metric exactly when a fresh connect refuses.
        events = [
            {"event": "connect_failed", "error": "Connection refused",
             "fresh": True, "attempt": 0, "wallSec": 0.1},
        ]
        metrics = bench_metrics.summarize_trial("t", events)
        self.assertEqual(len(metrics["watchdog_events"]), 1)
        self.assertEqual(metrics["watchdog_events"][0]["event"], "connect_failed")

    def test_live_line_renders_connect_failed(self):
        line = bench_metrics.live_progress_line(
            {"event": "connect_failed", "error": "Connection refused",
             "fresh": True, "attempt": 1}
        )
        self.assertIn("[fa-bench] connect failed", line)
        self.assertIn("Connection refused", line)
        self.assertIn("attempt 1", line)


class LiveProgressTest(unittest.TestCase):
    def test_live_line_format_contract(self):
        cases = [
            (
                {"event": "request_start", "seq": 12, "method": "POST",
                 "url": "https://x/v1", "fresh": None},
                "[fa-bench] req#12 sent",
            ),
            (
                {"event": "first_byte", "seq": 12, "wallSec": 213.0,
                 "slow": True, "fresh": False, "localPort": 54321,
                 "poolSize": 2, "connAgeSec": 912.0},
                "[fa-bench] req#12 first byte after 213s "
                "⚠ (reused, pool=2, port=54321)",
            ),
            (
                {"event": "first_byte", "seq": 12, "wallSec": 12.0,
                 "slow": False, "fresh": True, "localPort": 54321,
                 "poolSize": 2, "connAgeSec": 0.0},
                "[fa-bench] req#12 first byte after 12s (fresh, pool=2)",
            ),
            (
                {"event": "idle_watchdog_fired", "idleSec": 300.0,
                 "connAgeSec": 912.0, "localPort": 54321},
                "[fa-bench] idle-watchdog FIRED after 300s "
                "(conn age 912s, port 54321)",
            ),
            (
                {"event": "connect_watchdog_fired", "timeoutSec": 120.0,
                 "attempt": 0},
                "[fa-bench] connect-watchdog FIRED after 120s (attempt 0)",
            ),
            (
                {"event": "retry", "attempt": 1, "delaySec": 2.0,
                 "reason": "connect stall: no response bytes"},
                "[fa-bench] retry #1 in 2s (connect stall: no response bytes)",
            ),
            (
                {"event": "stale_socket", "localPort": 54321, "ageSec": 912.0,
                 "error": "connection reset by peer"},
                "[fa-bench] stale socket port 54321 (age 912s): "
                "connection reset by peer",
            ),
            (
                {"event": "request_done", "seq": 12, "statusCode": 200},
                "[fa-bench] req#12 done status 200",
            ),
        ]
        for event, expected in cases:
            self.assertEqual(bench_metrics.live_progress_line(event), expected)

    def test_unknown_events_render_nothing(self):
        self.assertIsNone(
            bench_metrics.live_progress_line({"event": "future_event"})
        )

    def test_live_progress_flushes_each_line(self):
        out = _FlushCounter()
        progress = bench_metrics.LiveProgress(out)
        progress.feed(
            'FA_CONN {"event":"retry","attempt":1,"delaySec":2.0,"reason":"r"}\n'
        )
        self.assertEqual(out.getvalue(), "[fa-bench] retry #1 in 2s (r)\n")
        self.assertEqual(out.flush_count, 1)


class _FlushCounter(StringIO):
    def __init__(self):
        super().__init__()
        self.flush_count = 0

    def flush(self):
        self.flush_count += 1
        super().flush()


class SessionGapTest(unittest.TestCase):
    def test_max_assistant_record_gap(self):
        records = [
            json.dumps({"type": "session", "version": 3, "id": "s",
                        "timestamp": "2026-01-01T00:00:00Z", "cwd": "/x"}),
            json.dumps({"type": "message", "id": "a", "timestamp":
                        "2026-01-01T00:01:00Z",
                        "message": {"role": "assistant", "content": "hi"}}),
            json.dumps({"type": "message", "id": "b", "timestamp":
                        "2026-01-01T00:02:30Z",
                        "message": {"role": "user", "content": "go"}}),
            json.dumps({"type": "message", "id": "c", "timestamp":
                        "2026-01-01T00:06:00Z",
                        "message": {"role": "assistant", "content": "done"}}),
        ]
        # Inter-ASSISTANT-record gaps: the user turn at 00:02:30 is not a
        # record boundary — the gap spans 00:01:00 -> 00:06:00.
        gaps = bench_metrics.session_assistant_gaps("\n".join(records))
        self.assertEqual(gaps, [300.0])
        self.assertEqual(bench_metrics.max_session_gap("\n".join(records)), 300.0)

    def test_missing_or_corrupt_degrades_to_none(self):
        self.assertIsNone(bench_metrics.max_session_gap(""))
        self.assertIsNone(bench_metrics.max_session_gap("garbage\nlines"))
        self.assertIsNone(bench_metrics.max_session_gap(
            json.dumps({"type": "message", "id": "a",
                        "message": {"role": "assistant"}})))


class FullNarrativePaneTest(unittest.TestCase):
    """gh-1433 AC7: the parsers stay correct on FULL-NARRATIVE pane
    captures. Since the log-fidelity flip a headless fa -p pane carries
    dimmed thinking deltas, streamed assistant prose, and tool rows
    BETWEEN the FA_CONN lines (and no longer ends at the tool-only
    shape). The parse contract is fail-soft noise tolerance: conn events,
    session gaps, and verdicts must fold identically on both captures.
    """

    # The same two FA_CONN events, once on a tool-only pane (the
    # pre-flip capture shape) and once interleaved with the full
    # narrative a gh-1433 pane now carries.
    conn_lines = [
        'FA_CONN {"event":"first_byte","seq":1,"wallSec":12.5,'
        '"fresh":true,"localPort":51000,"poolSize":0}',
        'FA_CONN {"event":"first_byte","seq":2,"wallSec":3.25,'
        '"fresh":false,"localPort":51001,"poolSize":1}',
    ]

    tool_only_pane = "\n".join(
        [
            "✓ bash · echo hi 0s",
            conn_lines[0],
            "• read · /work/main.dart",
            conn_lines[1],
        ]
    )

    full_narrative_pane = "\n".join(
        [
            "\x1b[2mI should check the layout first and count the rows.\x1b[0m",
            "Reading the entry point now.",
            "• bash · echo hi",
            conn_lines[0],
            "│ ✓ bash · echo hi 0s",
            "\x1b[2mthe output looks clean — moving on to the next step\x1b[0m",
            "All done \u2014 found it.",
            "fa-tokens: {\"sessionId\":\"abc\",\"input\":10,\"output\":2}",
            conn_lines[1],
            "┌─ bash task completed in background (2s)",
            "│ ps -o pid,ppid,etime,pcpu,args -p $(pgrep -f test.dart)",
            "│ log: /home/runner/work/repo/.fah/bash_jobs/sh-1/job.log",
            "└" + "\u2500" * 60,
        ]
    )

    def test_conn_events_identical_on_both_capture_shapes(self):
        tool_only = bench_metrics.parse_conn_events(self.tool_only_pane)
        narrative = bench_metrics.parse_conn_events(self.full_narrative_pane)
        self.assertEqual(tool_only, narrative)
        self.assertEqual([e["seq"] for e in narrative], [1, 2])
        self.assertEqual(
            [r["first_byte_sec"] for r in bench_metrics.summarize_trial(
                "t", narrative)["requests"]],
            [12.5, 3.25],
        )

    def test_summary_folds_identically_on_both_capture_shapes(self):
        a = bench_metrics.summarize_trial(
            "t", bench_metrics.parse_conn_events(self.tool_only_pane)
        )
        b = bench_metrics.summarize_trial(
            "t", bench_metrics.parse_conn_events(self.full_narrative_pane)
        )
        self.assertEqual(
            a["latency"]["first_byte"]["p50"],
            b["latency"]["first_byte"]["p50"],
        )
        self.assertEqual(a["latency"]["fresh_requests"],
                         b["latency"]["fresh_requests"])
        self.assertEqual(a["requests"], b["requests"])
        self.assertEqual(a["watchdog_events"], b["watchdog_events"])

    def test_session_gaps_ignores_narrative_noise_between_records(self):
        records = [
            json.dumps({"type": "message", "id": "a", "timestamp":
                        "2026-01-01T00:01:00Z",
                        "message": {"role": "assistant", "content": "hi"}}),
            # The gh-1433 pane bytes a human sees BETWEEN session records
            # are log lines, not records \u2014 the gap math must skip them.
            "\x1b[2mthinking about the next step\x1b[0m",
            "• bash · ls",
            "text prose between turns",
            json.dumps({"type": "message", "id": "b", "timestamp":
                        "2026-01-01T00:02:00Z",
                        "message": {"role": "assistant", "content": "done"}}),
        ]
        text = "\n".join(records)
        self.assertEqual(bench_metrics.session_assistant_gaps(text), [60.0])
        self.assertEqual(bench_metrics.max_session_gap(text), 60.0)

    def test_live_progress_flashes_one_line_per_event_on_a_narrative_pane(self):
        out = StringIO()
        progress = bench_metrics.LiveProgress(out=out)
        progress.feed(self.full_narrative_pane)
        lines = [l for l in out.getvalue().splitlines() if l.strip()]
        self.assertEqual(len(lines), 2, lines)


class ScoreHonestyTest(unittest.TestCase):
    """AC8: an agent_timeout trial with steady gaps is a loud violation."""

    def test_agent_timeout_with_steady_gaps_violates(self):
        self.assertTrue(
            bench_metrics.score_honesty_violation(
                "agent_timeout", max_gap_sec=166.0, stall_gap_sec=240.0
            )
        )

    def test_agent_timeout_with_a_real_stall_is_honest(self):
        self.assertFalse(
            bench_metrics.score_honesty_violation(
                "agent_timeout", max_gap_sec=491.0, stall_gap_sec=240.0
            )
        )

    def test_other_modes_and_unknown_gaps_never_violate(self):
        self.assertFalse(
            bench_metrics.score_honesty_violation(
                "no_problems_found", max_gap_sec=166.0, stall_gap_sec=240.0
            )
        )
        self.assertFalse(
            bench_metrics.score_honesty_violation(
                "agent_timeout", max_gap_sec=None, stall_gap_sec=240.0
            )
        )


class HeartbeatInterleaveTest(unittest.TestCase):
    """gh-1430 AC6 (REG-R2): fa's `… reasoning Ns (streaming)` heartbeat
    lines ride the pane stream alongside FA_CONN events; the metrics
    parsers must treat them as inert noise — a capture with interleaved
    heartbeats parses identically to one without."""

    _CAPTURE = [
        "some pane noise",
        'FA_CONN {"event":"request_start","seq":1,"method":"POST",'
        '"url":"https://x/v1","fresh":null}',
        "… reasoning 60s (streaming)",
        "… reasoning 120s (streaming)",
        'FA_CONN {"event":"first_byte","seq":1,"wallSec":213.0,"slow":true,'
        '"fresh":true,"localPort":54321,"poolSize":2,"connAgeSec":912.0}',
        "⏳ [bash] sleep 500 — running 120s · consider background: true …",
        "… reasoning 180s (streaming)",
        'FA_CONN {"event":"retry","attempt":1,"delaySec":2.0,'
        '"reason":"connect stall: no response bytes"}',
    ]

    def test_conn_event_parsing_ignores_heartbeats(self):
        with_hearts = bench_metrics.parse_conn_events(
            "\n".join(self._CAPTURE)
        )
        without = bench_metrics.parse_conn_events(
            "\n".join(line for line in self._CAPTURE
                      if "reasoning" not in line)
        )
        self.assertEqual(with_hearts, without)
        self.assertEqual(
            [e["event"] for e in with_hearts],
            ["request_start", "first_byte", "retry"],
        )

    def test_live_progress_output_ignores_heartbeats(self):
        out_with = StringIO()
        bench_metrics.LiveProgress(out=out_with).feed(
            "\n".join(self._CAPTURE) + "\n"
        )
        out_without = StringIO()
        bench_metrics.LiveProgress(out=out_without).feed(
            "\n".join(line for line in self._CAPTURE
                      if "reasoning" not in line) + "\n"
        )
        self.assertEqual(out_with.getvalue(), out_without.getvalue())
        self.assertEqual(out_with.getvalue().count("[fa-bench]"), 3)

    def test_trial_summary_is_heartbeat_free(self):
        events = bench_metrics.parse_conn_events("\n".join(self._CAPTURE))
        metrics = bench_metrics.summarize_trial("t1__trial", events)
        flat = json.dumps(metrics)
        self.assertNotIn("reasoning", flat)
        self.assertEqual(len(metrics["requests"]), 1)


class StallGapYardstickCouplingTest(unittest.TestCase):
    """gh-1430 AC4: the AC8 yardstick must mirror the shipped watch gap.

    bench_metrics.DEFAULT_STALL_GAP_SEC drives summary.py's legacy
    contradiction scan and post_mortem_usage's default; it must never
    disagree with bench/fa_agent_timeout.py's _STALL_GAP_DEFAULT (the
    ProgressWatch freeze boundary this yardstick audits).
    """

    def test_default_matches_the_shared_watch_gap(self):
        self.assertEqual(
            bench_metrics.DEFAULT_STALL_GAP_SEC,
            fa_agent_timeout._STALL_GAP_DEFAULT,
        )


if __name__ == "__main__":
    unittest.main()
