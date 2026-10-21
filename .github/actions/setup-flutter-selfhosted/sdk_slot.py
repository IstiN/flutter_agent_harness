#!/usr/bin/env python3
"""SDK-slot primitives for the setup-flutter-selfhosted composite action.

Layout under $HOME/actions-runner-yoloit/flutter-sdk/:

    <version>/     one immutable tree per pinned Flutter version
      .fah-arch    arch stamp written into each slot at install time
                   (gh-1736): lets ensure_arch tell a healthy slot
                   from one unpacked from a wrong-arch archive
    current        symlink to the version every new job should use
    .fah-version   advisory marker of the version `current` targets

Concurrency contract (#357 review): build-macos.yml runs its arm64 and
x86_64 matrix legs CONCURRENTLY on the ONE self-hosted runner, so two
legs can execute this action in the same instant. Every mutation below
is a single atomic syscall (rename(2), or symlink+os.replace) or an
idempotent converge-the-loser, which makes the interleavings harmless by
construction instead of by locking:

  resolve   pure decision: manifest + marker -> SKIP / REUSE / INSTALL
  migrate   one-time move of a legacy real-dir `current` into its slot
  install   rename(2) of a fully-staged tree into <version>/ — the loser
            of a concurrent install of the same pin finds an identical
            tree in the slot and discards its duplicate (both legs
            download the same archive, so the bytes are identical; the
            wasted download is bounded and one-time per cold start)
  flip      symlink swap of `current` via os.replace — readers resolve
            either the old complete tree or the new complete tree, never
            a missing or half-populated slot
  gc        reclaim superseded version trees after a drain window and
            staging dirs abandoned by jobs that died mid-download
  archive   pure resolution: version + host arch -> releases_macos.json
            archive filename (arm64 zips carry the _arm64 infix, x64
            zips carry none — gh-1736)
  ensure_arch  prune a slot whose stamp is missing or not the host
            arch, so the action reinstalls it from the right archive

The manifest source can be overridden with FAH_RELEASES_MANIFEST (a URL
or a local file path) — that is how the committed scenarios in
test/setup_flutter_selfhosted_test.dart drive the decision logic without
the network.
"""

import json
import os
import re
import shutil
import sys
import time
import urllib.request

RELEASES_URL = (
    'https://storage.googleapis.com/flutter_infra_release/releases/'
    'releases_macos.json'
)
VERSION_RE = re.compile(r'^\d+\.\d+\.\d+$')
ARCH_STAMP = '.fah-arch'


def read_marker(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ''


def spec_prefix(spec):
    # '3.47.x' -> '3.47.' ; exact specs (3.47.4) -> None
    return spec[:-1] if spec.endswith('x') else None


def satisfies(spec, version):
    prefix = spec_prefix(spec)
    if prefix is not None:
        return version.startswith(prefix)
    return version == spec


def manifest_source():
    src = os.environ.get('FAH_RELEASES_MANIFEST')
    if src and '://' not in src:  # bare filesystem path -> file:// URL
        src = 'file://' + os.path.abspath(src)
    return src or RELEASES_URL


def cmd_resolve(spec, marker_path):
    """Print the SKIP/REUSE/INSTALL verdict for this run.

    Same resolution subosito/flutter-action performs: newest stable
    release matching the spec wins. Degrades to REUSE when the manifest
    is unreachable but the pinned SDK still satisfies the spec; hard
    error only when no install could satisfy the spec at all.
    """
    marked = read_marker(marker_path)

    wanted = None
    try:
        with urllib.request.urlopen(manifest_source(), timeout=30) as r:
            releases = json.load(r)['releases']
        best = None
        for rel in releases:
            v = rel.get('version', '')
            if rel.get('channel') == 'stable' and satisfies(spec, v):
                key = tuple(int(p) for p in v.split('.'))
                if best is None or key > best[0]:
                    best = key, v
        if best is not None:
            wanted = best[1]
    except Exception as e:  # noqa: BLE001 — degrade, never fail the job here
        print(f'manifest fetch failed: {e}', file=sys.stderr)

    if wanted is not None and wanted == marked:
        print(f'SKIP {wanted}')
    elif wanted is None and marked and satisfies(spec, marked):
        print(f'REUSE {marked}')
    elif wanted is not None:
        print(f'INSTALL {wanted}')
    else:
        print(f'no stable release matches {spec!r} and no pinned SDK '
              f'satisfies it (marker: {marked!r})', file=sys.stderr)
        sys.exit(1)


def cmd_migrate(root, marker_path):
    """Move a pre-#357 real-dir `current` into its per-version slot.

    The old layout kept the live SDK in `current` itself and swapped it
    with rm+mv — the race the review flagged. Migration is idempotent
    and race-tolerant: os.rename never merges, so the loser of two
    concurrent migrations no-ops and lets the winner's identical tree
    stand. An unmarked legacy dir is junk (no version claims it) and is
    dropped; a missing slot self-heals through INSTALL.
    """
    current = os.path.join(root, 'current')
    if os.path.islink(current) or not os.path.isdir(current):
        return
    marked = read_marker(marker_path)
    dest = os.path.join(root, marked)
    if marked and VERSION_RE.match(marked) and not os.path.exists(dest):
        try:
            os.rename(current, dest)
        except OSError:
            pass  # a concurrent leg migrated first — identical tree
    else:
        shutil.rmtree(current, ignore_errors=True)


def cmd_install(staged, dest):
    """Atomically slot a fully-downloaded staged tree in as <version>/.

    rename(2) is all-or-nothing: it either lands the complete tree in an
    empty slot or fails because the slot is occupied — it can never
    merge into or half-replace one (BSD mv(1) silently NESTS a source
    directory into an occupied destination, which is why this is
    os.rename and not `mv`). Two legs racing an install of the same pin
    resolve the same version and download the same archive, so the
    loser's tree is redundant: discard it and reuse the winner's.
    """
    try:
        os.rename(staged, dest)
        print(f'installed {dest}')
    except OSError as e:
        if os.path.isdir(dest):
            print(f'{dest} already installed by a concurrent leg — '
                  f'discarding this duplicate download ({e})')
            shutil.rmtree(staged, ignore_errors=True)
        else:
            raise


def cmd_flip(target, link):
    """Point `current` at target with one atomic rename(2).

    os.replace swaps the symlink in a single syscall: a reader resolving
    `current` sees either the previous complete version or the new one,
    never a missing link (rm-then-mv, as the pre-#357 code did, is
    exactly the window where a marker can end up pointing at a deleted
    SDK). Flipping to the already-live target is a no-op, so concurrent
    legs of a matrix run converge on the same link.
    """
    tmp = f'{link}.flip.{os.getpid()}'
    if os.path.lexists(tmp):
        os.remove(tmp)
    os.symlink(target, tmp)
    os.replace(tmp, link)
    print(f'current -> {os.readlink(link)}')


def cmd_gc(root, keep, min_age_days):
    """Reclaim superseded version trees and stale download stages.

    Only directories other than the live target (`keep`) are eligible,
    and only after a drain window: an in-flight job that already
    resolved an older version through `current` keeps a complete tree
    beneath its open files. Version dirs carry their unzip mtime, so a
    fresh concurrent install is never eligible; staging dirs left by a
    job that died mid-download go after one day.
    """
    now = time.time()
    for name in os.listdir(root):
        path = os.path.join(root, name)
        try:
            age_days = (now - os.stat(path).st_mtime) / 86400.0
        except OSError:
            continue
        if name.startswith('.stage.') and age_days >= 1:
            shutil.rmtree(path, ignore_errors=True)
        elif VERSION_RE.match(name) and path != keep \
                and age_days >= min_age_days:
            print(f'gc: removed superseded SDK {name} '
                  f'(older than {min_age_days:g}d)')
            shutil.rmtree(path, ignore_errors=True)


def normalise_arch(host_arch):
    """Map uname -m output to the manifest's dart_sdk_arch vocabulary."""
    arch = (host_arch or '').strip().lower()
    if arch == 'arm64':
        return 'arm64'
    if arch in ('x86_64', 'amd64', 'x64'):
        return 'x64'
    return ''


def cmd_archive(version, host_arch):
    """Print the releases_macos.json archive filename for this host arch.

    gh-1736: the arch-less flutter_macos_<v>-stable.zip is the X64
    build; installing it on the arm64 self-hosted runner slots an x64
    dart that dies with 'Bad CPU type in executable' (exit 126). Per
    the manifest convention, arm64 archives carry the _arm64 infix and
    x64 archives carry none — the same pick subosito/flutter-action
    makes from the platform arch. Pure: no network, no filesystem.
    """
    if not VERSION_RE.match(version):
        raise ValueError(f'not a concrete version: {version!r}')
    arch = normalise_arch(host_arch)
    if not arch:
        raise ValueError(
            f'unsupported host arch {host_arch!r} — cannot pick a macOS '
            f'Flutter SDK archive (need arm64 or x86_64/x64)')
    infix = '_arm64' if arch == 'arm64' else ''
    print(f'flutter_macos{infix}_{version}-stable.zip')


def cmd_ensure_arch(dest, host_arch):
    """Prune a slot installed for a different (or unknown) arch.

    A marker can point at a slot whose contents were unpacked from the
    wrong-arch archive — or, like the gh-1736 poisoned runner slot, from
    the pre-fix arch-less download (no stamp at all). resolve() answers
    SKIP for it forever, so the action runs this before trusting a
    SKIP/REUSE verdict: a slot stamped for the host arch stays, anything
    else is removed and reported as `reinstall` for the INSTALL path.
    Race-safe in the two-legs-one-runner topology: both concurrent legs
    share the host arch, so a prune never removes a tree the other leg
    installed for itself — the loser converges on the winner's
    correctly stamped slot.
    """
    arch = normalise_arch(host_arch)
    if not arch:
        raise ValueError(f'unsupported host arch {host_arch!r}')
    if not os.path.isdir(dest):
        print('ok')
        return
    stamp = ''
    try:
        with open(os.path.join(dest, ARCH_STAMP)) as f:
            stamp = f.read().strip()
    except OSError:
        pass
    # The action stamps slots with the raw `uname -m` spelling; compare
    # it in the SAME normalised vocabulary as the host side, so the
    # stamp round-trips at both arches — on x86_64 the raw spelling and
    # the manifest vocabulary differ (`x86_64` vs `x64`), and without
    # this normalisation the freshly stamped slot was pruned and
    # re-downloaded on every run (gh-1736 review). An unrecognised
    # stamp survives as-is and still mismatches — never trusted.
    stamp = normalise_arch(stamp) or stamp
    if stamp == arch:
        print('ok')
        return
    print(f'reinstall: slot arch {stamp or "unstamped"} != host {arch}')
    shutil.rmtree(dest, ignore_errors=True)


def main(argv):
    usage = ('usage: sdk_slot.py resolve SPEC MARKER | migrate ROOT MARKER '
             '| install STAGED DEST | flip TARGET LINK | gc ROOT KEEP '
             'MIN_AGE_DAYS | archive VERSION HOST_ARCH | '
             'ensure_arch DEST HOST_ARCH')
    if len(argv) < 2:
        print(usage, file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    try:
        if cmd == 'resolve' and len(args) == 2:
            cmd_resolve(args[0], args[1])
        elif cmd == 'migrate' and len(args) == 2:
            cmd_migrate(args[0], args[1])
        elif cmd == 'install' and len(args) == 2:
            cmd_install(args[0], args[1])
        elif cmd == 'flip' and len(args) == 2:
            cmd_flip(args[0], args[1])
        elif cmd == 'gc' and len(args) == 3:
            cmd_gc(args[0], args[1], float(args[2]))
        elif cmd == 'archive' and len(args) == 2:
            cmd_archive(args[0], args[1])
        elif cmd == 'ensure_arch' and len(args) == 2:
            cmd_ensure_arch(args[0], args[1])
        else:
            print(usage, file=sys.stderr)
            return 2
    except Exception as e:  # noqa: BLE001 — surfaces as a failed step
        print(f'sdk_slot {cmd} failed: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
