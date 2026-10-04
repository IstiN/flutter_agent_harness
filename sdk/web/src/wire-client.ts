/// Agent Wire Protocol v1 reference client for the web (issue #1101,
/// `sdk/web`). A thin, dependency-free TypeScript mirror of the canonical
/// Dart contract in `lib/src/wire/wire_protocol.dart`:
///
/// - handshake (`hello`/`welcome`, max-overlap version negotiation, LOUD
///   `WireVersionError` on no overlap),
/// - command builders (`prompt`, `steer`, `abort`, `approval_response`,
///   `ask_response`, `secret_response`, `session_control`) reproducing the
///   golden frames in `test/wire/fixtures/v1/commands/` byte-shape-for-shape,
/// - event decoding that classifies every frame (`known` / `request` /
///   `unknown`), tolerates unknown fields, and degrades unknown kinds to the
///   documented passthrough so the run stays alive (E3),
/// - NDJSON framing (one JSON object per line — NOT JSONP),
/// - the E4 secret registry: `redactForLog` before you log or persist.
///
/// The client carries frames; it does NOT reconstruct engine objects. A host
/// renders off the frame (partial-first: `message_update.message` IS the live
/// snapshot) and answers request frames with the matching response command.
/// Conformance against the golden fixtures runs in `test/conformance.test.mjs`
/// and is CI-pinned from the Dart side by
/// `test/wire/web_client_conformance_test.dart`.
///
/// Erasable-syntax TypeScript only (type stripping runs it directly on
/// node >= 22.18); zero dependencies.

/** The native protocol version this client speaks. */
export const WIRE_VERSION = 1;

/** Every protocol version this client can encode and decode. */
export const SUPPORTED_VERSIONS: readonly number[] = [1];

/** The wire spelling of every event kind this client knows natively. */
export const KNOWN_EVENT_KINDS: readonly string[] = [
  'agent_start',
  'agent_end',
  'agent_settled',
  'turn_start',
  'turn_end',
  'message_start',
  'message_update',
  'message_end',
  'tool_execution_start',
  'tool_execution_update',
  'tool_execution_end',
  'model_request',
  'tool_pairing_repair',
  'tool_call_heartbeat',
  'tool_call_stuck',
];

/** Host-interaction request kinds — answered with the matching `_response` command. */
export const REQUEST_EVENT_KINDS: readonly string[] = [
  'approval_request',
  'ask_request',
  'secret_request',
];

export interface WireFrame {
  v: number;
  kind: string;
  [field: string]: unknown;
}

/** A malformed frame or a structurally invalid payload — loud by design. */
export class WireProtocolError extends Error {}

/** The loud handshake failure when no protocol version overlaps. */
export class WireVersionError extends WireProtocolError {}

/** One decoded event frame: classification plus the raw frame. */
export type DecodedWireEvent =
  | { type: 'known'; kind: string; frame: WireFrame }
  | {
      type: 'request';
      kind: string;
      requestId: string;
      frame: WireFrame;
    }
  | { type: 'unknown'; kind: string; frame: WireFrame };

export interface AskAnswer {
  selected?: string[];
  freeText?: string;
}

export interface SecretResult {
  name: string;
  value: string;
  persisted: boolean;
}

export type ApprovalDecision = 'approve_once' | 'approve_always' | 'deny';

const APPROVAL_DECISIONS: readonly string[] = [
  'approve_once',
  'approve_always',
  'deny',
];

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

/** Builds the client `hello` frame. */
export function helloFrame(
  opts: {
    versions?: readonly number[];
    caps?: readonly string[];
    v?: number;
  } = {},
): WireFrame {
  const versions = opts.versions ?? SUPPORTED_VERSIONS;
  return {
    v: opts.v ?? WIRE_VERSION,
    kind: 'hello',
    versions: [...versions],
    ...(opts.caps?.length ? { caps: [...opts.caps] } : {}),
  };
}

/** The highest version from [clientVersions] this client supports. */
export function negotiate(clientVersions: readonly number[]): number {
  const overlap = clientVersions.filter((v) => SUPPORTED_VERSIONS.includes(v));
  if (overlap.length === 0) {
    throw new WireVersionError(
      `no protocol version overlap: client offers [${clientVersions}], ` +
        `server supports [${[...SUPPORTED_VERSIONS]}]`,
    );
  }
  return Math.max(...overlap);
}

/**
 * Validates the server `welcome` against the versions this client offered
 * and returns the negotiated version. A welcome outside the offer is a LOUD
 * error — the connection must not limp on a guessed version.
 */
export function acceptWelcome(
  frame: WireFrame,
  offered: readonly number[] = SUPPORTED_VERSIONS,
): number {
  if (frame.kind !== 'welcome') {
    throw new WireProtocolError(
      `expected a welcome frame, got kind: ${frame.kind}`,
    );
  }
  const negotiated = frame.version;
  if (typeof negotiated !== 'number' || !Number.isInteger(negotiated)) {
    throw new WireProtocolError(
      'welcome frame must carry an integer version',
    );
  }
  if (!offered.includes(negotiated)) {
    throw new WireVersionError(
      `server negotiated version ${negotiated}, which this client ` +
        `did not offer ([${[...offered]}])`,
    );
  }
  return negotiated;
}

/** Builds the documented `unknown_event` passthrough frame. */
export function encodeUnknownEvent(
  originalKind: string,
  payload: Record<string, unknown> = {},
  version = WIRE_VERSION,
): WireFrame {
  return {
    v: version,
    kind: 'unknown_event',
    originalKind,
    payload,
  };
}

// ---------------------------------------------------------------------------
// Commands (host → engine) — mirrors Dart `WireCommand.toJson`, key order included.
// ---------------------------------------------------------------------------

export function promptCommand(text: string, version = WIRE_VERSION): WireFrame {
  return { v: version, kind: 'prompt', text };
}

export function steerCommand(text: string, version = WIRE_VERSION): WireFrame {
  return { v: version, kind: 'steer', text };
}

export function abortCommand(version = WIRE_VERSION): WireFrame {
  return { v: version, kind: 'abort' };
}

export function approvalResponseCommand(
  id: string,
  decision: ApprovalDecision,
  version = WIRE_VERSION,
): WireFrame {
  if (!APPROVAL_DECISIONS.includes(decision)) {
    throw new WireProtocolError(`unknown approval decision: ${decision}`);
  }
  return { v: version, kind: 'approval_response', id, decision };
}

export function askResponseCommand(
  id: string,
  answers: AskAnswer[] | null,
  version = WIRE_VERSION,
): WireFrame {
  // `answers: null` is the user cancelling; otherwise one answer per
  // question, in question order, omitting empty `selected` and absent
  // `freeText` — exactly the Dart encoder's canonical shape (key order
  // included: `cancelled` precedes `answers`).
  const answersShape =
    answers === null
      ? {}
      : {
          answers: answers.map((answer) => ({
            ...(answer.selected?.length
              ? { selected: [...answer.selected] }
              : {}),
            ...(answer.freeText != null ? { freeText: answer.freeText } : {}),
          })),
        };
  return {
    v: version,
    kind: 'ask_response',
    id,
    cancelled: answers === null,
    ...answersShape,
  };
}

export function secretResponseCommand(
  id: string,
  result: SecretResult | null,
  version = WIRE_VERSION,
): WireFrame {
  // E4: `result.value` is SECRET-class — redact before logging.
  return {
    v: version,
    kind: 'secret_response',
    id,
    granted: result !== null,
    ...(result !== null
      ? {
          name: result.name,
          value: result.value,
          persisted: result.persisted,
        }
      : {}),
  };
}

export function sessionControlCommand(
  op: string,
  params: Record<string, unknown> = {},
  version = WIRE_VERSION,
): WireFrame {
  return {
    v: version,
    kind: 'session_control',
    op,
    ...(Object.keys(params).length > 0 ? { params } : {}),
  };
}

// ---------------------------------------------------------------------------
// Events (engine → host)
// ---------------------------------------------------------------------------

function requireString(frame: WireFrame, field: string): string {
  const value = frame[field];
  if (typeof value === 'string' && value.length > 0) return value;
  throw new WireProtocolError(`field "${field}" must be a non-empty string`);
}

/**
 * Decodes an event frame. Unknown kinds (and `unknown_event` itself) return
 * the `unknown` passthrough; malformed known frames and unsupported versions
 * throw the declared errors.
 */
export function decodeEvent(frame: WireFrame): DecodedWireEvent {
  const version = frame.v;
  if (
    typeof version !== 'number' ||
    !Number.isInteger(version) ||
    !SUPPORTED_VERSIONS.includes(version)
  ) {
    throw new WireVersionError(
      `event frame carries unsupported version ${String(version)} ` +
        `(supported: [${[...SUPPORTED_VERSIONS]}])`,
    );
  }
  const kind = frame.kind;
  if (typeof kind !== 'string' || kind.length === 0) {
    throw new WireProtocolError('event frame is missing its kind');
  }
  if ((REQUEST_EVENT_KINDS as readonly string[]).includes(kind)) {
    return {
      type: 'request',
      kind,
      requestId: requireString(frame, 'id'),
      frame,
    };
  }
  if ((KNOWN_EVENT_KINDS as readonly string[]).includes(kind)) {
    // The fields a host renders are checked loudly — the frame IS the payload.
    if (kind === 'message_update') {
      const nested = frame.event;
      if (
        nested === null ||
        typeof nested !== 'object' ||
        typeof (nested as WireFrame).kind !== 'string'
      ) {
        throw new WireProtocolError(
          'field "message_update.event" must be an object with a kind',
        );
      }
    }
    if (
      kind.startsWith('tool_') &&
      (kind === 'tool_execution_start' ||
        kind === 'tool_execution_update' ||
        kind === 'tool_execution_end' ||
        kind === 'tool_call_heartbeat' ||
        kind === 'tool_call_stuck')
    ) {
      requireString(frame, 'toolCallId');
      requireString(frame, 'toolName');
    }
    return { type: 'known', kind, frame };
  }
  if (kind === 'unknown_event') {
    const original = frame.originalKind;
    return {
      type: 'unknown',
      kind: typeof original === 'string' ? original : '<unnamed>',
      frame,
    };
  }
  // Forward-compat passthrough (E3): unknown kinds keep the run alive.
  return { type: 'unknown', kind, frame };
}

/** All text content of a message frame's `message`, in content order. */
export function messageText(message: unknown): string {
  if (message === null || typeof message !== 'object') return '';
  const content = (message as { content?: unknown }).content;
  if (!Array.isArray(content)) return '';
  return content
    .filter(
      (block): block is { type: 'text'; text: string } =>
        block !== null &&
        typeof block === 'object' &&
        (block as { type?: unknown }).type === 'text',
    )
    .map((block) => block.text)
    .join('');
}

// ---------------------------------------------------------------------------
// NDJSON framing
// ---------------------------------------------------------------------------

/** Frames one message as a single NDJSON line. One object per line — NOT JSONP. */
export function frameLine(frame: WireFrame): string {
  return `${JSON.stringify(frame)}\n`;
}

/**
 * Parses one NDJSON line. Blank lines return `null`; garbage throws
 * `SyntaxError`; a line whose JSON is not an object throws
 * `WireProtocolError`.
 */
export function parseLine(line: string): WireFrame | null {
  const trimmed = line.trim();
  if (trimmed.length === 0) return null;
  const decoded: unknown = JSON.parse(trimmed);
  if (
    decoded === null ||
    typeof decoded !== 'object' ||
    Array.isArray(decoded)
  ) {
    throw new WireProtocolError('NDJSON line must hold a JSON object');
  }
  return decoded as WireFrame;
}

// ---------------------------------------------------------------------------
// E4: secrets
// ---------------------------------------------------------------------------

const SECRET_FIELDS_BY_KIND: Record<string, readonly string[]> = {
  secret_response: ['value'],
  model_request: ['rawWireDump'],
};

const SECRET_FIELD_NAMES_ANYWHERE: readonly string[] = ['rawBody'];

/** Whether [field] of frame kind [kind] is SECRET-class (E4). */
export function isSecretField(kind: string, field: string): boolean {
  return (
    (SECRET_FIELDS_BY_KIND[kind]?.includes(field) ?? false) ||
    SECRET_FIELD_NAMES_ANYWHERE.includes(field)
  );
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === 'object' && value !== null && !Array.isArray(value)
  );
}

function redact(
  frame: Record<string, unknown>,
  kindLabel: string,
): Record<string, unknown> {
  const secretFields = SECRET_FIELDS_BY_KIND[kindLabel];
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(frame)) {
    if (
      (secretFields?.includes(key) ?? false) ||
      SECRET_FIELD_NAMES_ANYWHERE.includes(key)
    ) {
      out[key] = `[REDACTED:${kindLabel}]`;
    } else if (isPlainObject(value)) {
      out[key] = redact(value, kindLabel);
    } else if (Array.isArray(value)) {
      out[key] = value.map((item) =>
        isPlainObject(item) ? redact(item, kindLabel) : item,
      );
    } else {
      out[key] = value;
    }
  }
  return out;
}

/**
 * Deep-copies [frame] with every SECRET-class field replaced by the
 * repo-standard `[REDACTED:<kind>]` marker. Use for LOGGING and PERSISTENCE
 * copies only — the live frame keeps its values so the engine can work.
 */
export function redactForLog(frame: WireFrame): WireFrame {
  return redact(
    frame,
    typeof frame.kind === 'string' ? frame.kind : 'unknown',
  ) as WireFrame;
}
