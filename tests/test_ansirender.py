#!/usr/bin/env python3
"""Tests for lib/ansirender.py. Run: python3 tests/test_ansirender.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from ansirender import render  # noqa: E402

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


if __name__ == "__main__":
    unittest.main()
