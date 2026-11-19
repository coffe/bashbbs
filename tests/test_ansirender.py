#!/usr/bin/env python3
"""Tests for lib/ansirender.py. Run: python3 tests/test_ansirender.py"""
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from ansirender import render, render_ansi, sauce  # noqa: E402

E = "\x1b"


class Render(unittest.TestCase):
    def test_colours_go_text_stays(self):
        self.assertEqual(render(E + "[1;36m=== " + E + "[1;35mHi" + E + "[0m\nnext"), "=== Hi\nnext")

    def test_split_line_put_back(self):  # how echo-safe ads continue a long line
        self.assertEqual(render("abc\n" + E + "[A" + E + "[3Cdef\nghi"), "abcdef\nghi")

    def test_clear_and_position(self):
        self.assertEqual(render("junk" + E + "[2J" + E + "[H" + "top" + E + "[3;5Hx"), "top\n\n    x")

    def test_erase_to_end_of_line(self):
        self.assertEqual(render("abcdef\r" + E + "[2C" + E + "[K"), "ab")

    def test_save_restore_and_back(self):
        self.assertEqual(render("ab" + E + "[s" + "cd" + E + "[u" + "X" + E + "[3DY"), "YbXd")

    def test_80_columns_then_newline_is_one_line(self):
        self.assertEqual(render("x" * 80 + "\ny"), "x" * 80 + "\ny")
        self.assertEqual(render("x" * 81), "x" * 80 + "\nx")

    def test_sauce_cut_and_bounds(self):
        self.assertEqual(render("ad\x1aSAUCE00 title"), "ad")
        self.assertEqual(render(E + "[99999B" + E + "[99999Cz").count("\n"), 499)
        self.assertEqual(render(E + "]0;title\x07" + E + "[?25lok\x07"), "ok")


class RenderAnsi(unittest.TestCase):
    def test_colour_kept_cursor_moves_gone(self):
        got = render_ansi(E + "[2J" + E + "[1;31mA" + E + "[0m" + E + "[2;3H" + E + "[44m  " + E + "[0m")
        self.assertEqual(got, E + "[0;1;31mA" + E + "[0m\n  " + E + "[0;44m  " + E + "[0m")

    def test_only_sgr_comes_out(self):
        got = render_ansi(E + "]0;x\x07" + E + "[?25l" + E + "[5A" + E + "[31mhi\x07\x1b")
        self.assertEqual(re.findall("\x1b\\[[^m]*[^0-9;m]", got), [])
        self.assertEqual(render(got), "hi")

    def test_text_matches_render(self):
        art = E + "[1;1H" + E + "[33m" + "x" * 78 + E + "[70Dyy" + E + "[1;5H" + E + "[41mzz\r\n" + E + "[sq" + E + "[uw"
        self.assertEqual(render(render_ansi(art)), render(art))

    def test_ice_blink_is_bright_background(self):
        self.assertEqual(render_ansi(E + "[5;44mx", ice=True), E + "[0;104mx" + E + "[0m")
        self.assertEqual(render_ansi(E + "[5;44mx"), E + "[0;5;44mx" + E + "[0m")

    def test_sauce(self):
        rec = bytearray(b"SAUCE00" + b" " * 121)
        rec[94], rec[95], rec[96], rec[97], rec[105] = 1, 1, 160, 0, 1
        self.assertEqual(sauce(b"art\x1a" + bytes(rec)), (160, True))
        self.assertEqual(sauce(b"no sauce"), (80, False))

    def test_real_ad(self):
        ad = os.environ.get("ANSI_SAMPLE", "")  # a real ad from the echo; not kept in the repo
        if not os.path.exists(ad):
            self.skipTest("set ANSI_SAMPLE=<file.ans>")
        with open(ad, "rb") as fh:
            raw = fh.read().split(b"\x1a")[0].decode("cp437")
        got = render_ansi(raw)
        self.assertEqual(render(got), render(raw))
        self.assertNotRegex(got, "\x1b\\[[0-9;]*[ABCDHfJKsu]")


if __name__ == "__main__":
    unittest.main()
