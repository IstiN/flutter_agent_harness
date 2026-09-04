---
id: "n_0585_adcb"
type: "note"
title: "Pre-commit hook uses load-aware test concurrency (throttles to 2 when the 1-min load reaches half the cores; FA_*_TEST_CONCURRENCY override), and --concurrency=0 is invalid for dart test so the detector must return empty rather than zero."
author: "agent"
date: "2026-09-04T22:02:58.435229Z"
area: "project"
topics: []
source: "agent"
accessCount: 0
importance: 0.6
tags: ["#note", "#source_agent", "hook"]
---


# Note: n_0585_adcb

Pre-commit hook uses load-aware test concurrency (throttles to 2 when the 1-min load reaches half the cores; FA_*_TEST_CONCURRENCY override), and --concurrency=0 is invalid for dart test so the detector must return empty rather than zero.

**By:** [[agent]]
**Date:** 2026-09-04T22:02:58.435229Z
**Area:** [[project|project]]
