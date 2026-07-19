/// Hashline: a compact, line-anchored patch language and applier, ported
/// from oh-my-pi `packages/hashline`.
///
/// The model addresses edits by `[path#TAG]` section headers (a 4-hex
/// whole-file content hash minted by a hashline-mode `read` or a previous
/// edit) plus 1-indexed line anchors (`SWAP N.=M:`, `DEL N.=M`,
/// `INS.PRE|POST|HEAD|TAIL:`). A stale tag is rejected before any write, so
/// an edit can never silently land on drifted content.
///
/// Ported subset: tokenizer, parser, applier, snapshot store, and patcher
/// for the line-range ops. Skipped (documented in the respective libraries):
/// tree-sitter block ops (`SWAP.BLK`/`DEL.BLK`/`INS.BLK.POST`), file ops
/// (`REM`/`MV`), boundary-repair and landing-shift leniency passes, and
/// diff-based stale-anchor auto-remap.
library;

export 'apply.dart';
export 'format.dart';
export 'input.dart';
export 'messages.dart'
    show
        HashlineFormatException,
        bareBodyAutoPipedWarning,
        formatAnchoredContext,
        formatLineRanges,
        headTailDriftWarning,
        noChangeDiagnostic;
export 'mismatch.dart';
export 'normalize.dart';
export 'parser.dart' show HashlineParseResult, parseHashlinePatch;
export 'patcher.dart';
export 'snapshots.dart';
export 'types.dart';
export 'xxhash32.dart' show xxHash32;
