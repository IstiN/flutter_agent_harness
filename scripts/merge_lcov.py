#!/usr/bin/env python3
"""Properly merge lcov tracefiles (issue #177): `cat a.info b.info` is NOT a
valid merge — sharded coverage produces multiple SF: blocks for the SAME
source file, and naive concatenation makes downstream tools (CRAP, diff
coverage) see only one block's DA hits (methods covered by another shard
show 0%). This merger unions DA hit counts per (file, line), sums
LH/LF/BRF/BRH, and keeps one SF block per file.

Usage: merge_lcov.py -o coverage/lcov.info coverage-shards/*/lcov.info
Pure stdlib.
"""
import argparse
import sys


def merge(paths):
    # file -> {"DA": {line: hits}, "LF": int|None, "LH": int|None,
    #          "BRDA": {(line, block, branch): hits}, "BRF": int, "BRH": int,
    #          "FN": {}, "other": []}
    files = {}
    order = []
    for path in paths:
        cur = None
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if line.startswith("SF:"):
                    name = line[3:]
                    if name not in files:
                        files[name] = {"DA": {}, "BRDA": {}, "FN": {},
                                       "FNDA": {}, "other": []}
                        order.append(name)
                    cur = files[name]
                elif line.startswith("DA:") and cur is not None:
                    try:
                        ln, hits = line[3:].split(",")[:2]
                        ln = int(ln)
                        hits = int(float(hits))
                    except ValueError:
                        continue
                    cur["DA"][ln] = cur["DA"].get(ln, 0) + hits
                elif line.startswith("BRDA:") and cur is not None:
                    parts = line[5:].split(",")
                    if len(parts) >= 4:
                        key = tuple(parts[:3])
                        try:
                            hits = int(parts[3])
                        except ValueError:
                            hits = 0  # '-' = not executed
                        cur["BRDA"][key] = cur["BRDA"].get(key, 0) + hits
                elif line.startswith("FNDA:") and cur is not None:
                    try:
                        hits, fn = line[5:].split(",", 1)
                        cur["FNDA"][fn] = cur["FNDA"].get(fn, 0) + int(float(hits))
                    except ValueError:
                        pass
                elif line.startswith("FN:") and cur is not None:
                    cur["FN"][line] = None
                elif line.startswith(("TN:", "end_of_record")) or not line:
                    pass
                elif cur is not None:
                    cur["other"].append(line)
    return files, order


def render(files, order) -> str:
    out = []
    for name in order:
        cur = files[name]
        out.append("TN:")
        out.append(f"SF:{name}")
        for fn in sorted(cur["FN"]):
            out.append(fn)
        for fn, hits in sorted(cur["FNDA"].items()):
            out.append(f"FNDA:{hits},{fn}")
        if cur["FN"]:
            out.append(f"FNF:{len(cur['FN'])}")
            out.append(f"FNH:{sum(1 for h in cur['FNDA'].values() if h > 0)}")
        for (ln, block, branch), hits in sorted(cur["BRDA"].items(),
                                               key=lambda kv: (int(kv[0][0]), kv[0][1:])):
            out.append(f"BRDA:{ln},{block},{branch},{hits}")
        if cur["BRDA"]:
            out.append(f"BRF:{len(cur['BRDA'])}")
            out.append(f"BRH:{sum(1 for h in cur['BRDA'].values() if h > 0)}")
        for ln, hits in sorted(cur["DA"].items()):
            out.append(f"DA:{ln},{hits}")
        out.append(f"LF:{len(cur['DA'])}")
        out.append(f"LH:{sum(1 for h in cur['DA'].values() if h > 0)}")
        out.append("end_of_record")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()
    files, order = merge(args.inputs)
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(render(files, order))
    print(f"merged {len(args.inputs)} tracefiles -> {args.output} ({len(order)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
