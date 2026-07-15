#!/usr/bin/env python3
"""Generate known-answer vectors for the ascon_p RTL from the pyascon
reference implementation (dv/third_party/ascon_ref.py, CC0, by the Ascon
team — an implementation independent of our RTL).

Output: vectors.memh — flat $readmemh file, 21 words of 32 bits per test:
    word 0      : number of rounds (6, 8, or 12)
    words 1..10 : input state,  word[2j] = S[j] low 32, word[2j+1] = high 32
    words 11..20: expected output state, same layout

Tests: zero state, all-ones state, and deterministic random states, each
run at 6, 8, and 12 rounds.
"""
import pathlib
import random
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "third_party"))
from ascon_ref import ascon_permutation  # noqa: E402

MASK64 = (1 << 64) - 1


def emit(f, states, rounds_list):
    n = 0
    for s in states:
        for rounds in rounds_list:
            state = list(s)
            expect = list(s)
            ascon_permutation(expect, rounds)
            f.write(f"{rounds:08x}\n")
            for words in (state, expect):
                for j in range(5):
                    f.write(f"{words[j] & 0xFFFFFFFF:08x}\n")
                    f.write(f"{(words[j] >> 32) & 0xFFFFFFFF:08x}\n")
            n += 1
    return n


def main():
    rng = random.Random(0xA5C0)  # deterministic
    states = [[0] * 5, [MASK64] * 5]
    states += [[rng.getrandbits(64) for _ in range(5)] for _ in range(20)]

    out = HERE / "vectors.memh"
    with out.open("w", newline="\n") as f:
        n = emit(f, states, [6, 8, 12])
    print(f"wrote {out}: {n} tests")


if __name__ == "__main__":
    main()
