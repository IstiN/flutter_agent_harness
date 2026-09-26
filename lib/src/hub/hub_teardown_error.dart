// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by an MIT license that can be found
// in the LICENSE file.

/// Classifies hub-transport teardown errors that must never crash a host.
library;

/// Whether [error] is a fa_hub_client transport-teardown marker rather
/// than a real failure.
///
/// fa_hub_client fails its pending waiters with
/// `StateError('connection closed')` when the socket drops. Some waiters
/// outlive their listeners (e.g. a `flush()` waiter leaked when `_send`
/// throws synchronously on a dead socket): the late `completeError` then
/// lands in the zone as an UNHANDLED async error with an empty stack,
/// which no call-site try/catch can intercept. The messaging fabric
/// already falls back to the file fabric on connection loss, so this
/// error class is a benign teardown note — hosts should log it and keep
/// running instead of treating it as a crash.
bool isHubConnectionTeardown(Object error) =>
    error is StateError && error.message == 'connection closed';
