#!/usr/bin/env python3
"""Set one varint field in a Blackmagic preset (.cset) and write it back, every enclosing length recomputed.

    csetpatch.py in.cset out.cset <section> <path> <value>
    csetpatch.py p0.cset sdi-clean.cset metering 32[3].9 1      # MainSDI's clean feed on

<path> is dotted field numbers; [n] picks the nth repeat of a field (0-based), as csetdiff.py prints them."""
import re
import sys

from cset import parse


def enc_varint(v):
    out = bytearray()
    while True:
        byte = v & 0x7F
        v >>= 7
        if v:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def serialize(fields):
    out = bytearray()
    for field, wt, v in fields:
        out += enc_varint(field << 3 | wt)
        if wt == 0:
            out += enc_varint(v)
        elif wt == 2:
            out += enc_varint(len(v)) + v
        else:
            out += v
    return bytes(out)


def set_path(msg, steps, value):
    """steps: [(field, repeat)]; returns the message bytes with that varint set."""
    fields = parse(msg)
    (field, repeat), rest = steps[0], steps[1:]
    seen = -1
    for i, (f, wt, v) in enumerate(fields):
        if f != field:
            continue
        seen += 1
        if seen != repeat:
            continue
        if rest:
            assert wt == 2, f"field {field} isn't a message"
            fields[i] = (f, wt, set_path(v, rest, value))
        else:
            assert wt == 0, f"field {field} isn't a varint"
            fields[i] = (f, wt, value)
        return serialize(fields)
    raise SystemExit(f"no field {field}[{repeat}]")


def steps_of(path):
    out = []
    for part in path.split("."):
        m = re.fullmatch(r"(\d+)(?:\[(\d+)\])?", part)
        out.append((int(m.group(1)), int(m.group(2) or 0)))
    return out


if __name__ == "__main__":
    src, dst, section, path, value = sys.argv[1:6]
    top = parse(open(src, "rb").read())
    for i, (f, wt, v) in enumerate(top):
        if f == 10 and wt == 2:
            entry = parse(v)
            name = dict((ef, ev) for ef, _, ev in entry)[1].decode()
            if name == section:
                entry = [(ef, ewt, set_path(ev, steps_of(path), int(value)) if ef == 2 else ev) for ef, ewt, ev in entry]
                top[i] = (f, wt, serialize(entry))
                break
    else:
        raise SystemExit(f"no section {section}")
    data = serialize(top)
    assert serialize(parse(open(src, "rb").read())) == open(src, "rb").read(), "round trip changed the file"
    open(dst, "wb").write(data)
