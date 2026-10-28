#!/usr/bin/env python3
"""Tests for lib/wrap.py (vwidth, wrap, CLI). Run: python3 tests/test_wrap.py"""
import importlib.util
import os
import subprocess
import sys
import unicodedata
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
WRAP = os.path.join(HERE, "..", "lib", "wrap.py")
spec = importlib.util.spec_from_file_location("wrapmod", WRAP)
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


def cli(width, text):
    return subprocess.run([sys.executable, "-I", WRAP, str(width)],
                          input=text.encode(), capture_output=True)


class VWidth(unittest.TestCase):
    def test_ascii(self):
        self.assertEqual(w.vwidth("hello"), 5)
        self.assertEqual(w.vwidth(""), 0)

    def test_swedish_nfc_nfd_equal(self):
        s = "åäö ÅÄÖ"
        self.assertEqual(w.vwidth(unicodedata.normalize("NFC", s)), 7)
        self.assertEqual(w.vwidth(unicodedata.normalize("NFD", s)), 7)

    def test_cjk_is_double(self):
        self.assertEqual(w.vwidth("日本語"), 6)

    def test_zero_width(self):
        self.assertEqual(w.vwidth("a​b"), 2)


class Wrap(unittest.TestCase):
    def check_widths(self, lines, width):
        for l in lines:
            self.assertLessEqual(w.vwidth(l), width, repr(l))

    def test_simple(self):
        out = w.wrap("one two three four five", 10)
        self.assertEqual(out, ["one two", "three four", "five"])

    def test_exact_limit_fits(self):
        out = w.wrap("a" * 10, 10)
        self.assertEqual(out, ["a" * 10])
        out = w.wrap("aaaa bbbbb", 10)
        self.assertEqual(out, ["aaaa bbbbb"])

    def test_one_over_limit_breaks(self):
        out = w.wrap("aaaa bbbbbb", 10)
        self.assertEqual(out, ["aaaa", "bbbbbb"])

    def test_long_url_hard_split(self):
        url = "https://example.org/" + "x" * 80
        out = w.wrap("see " + url, 30)
        self.check_widths(out, 30)
        self.assertEqual("".join(out).replace("see", "", 1), url)

    def test_swedish_nfc_and_nfd(self):
        text = "Åsa åt äpplen och öl på ön " * 5
        for form in ("NFC", "NFD"):
            t = unicodedata.normalize(form, text)
            out = w.wrap(t, 20)
            self.check_widths(out, 20)
            self.assertEqual(" ".join(" ".join(out).split()),
                             " ".join(t.split()))

    def test_nfd_combining_not_split_from_base(self):
        t = unicodedata.normalize("NFD", "å" * 25)
        out = w.wrap(t, 10)
        self.check_widths(out, 10)
        for l in out:
            self.assertFalse(unicodedata.combining(l[0]), repr(l))

    def test_cjk(self):
        out = w.wrap("日本語のテキストをここで折り返します", 10)
        self.check_widths(out, 10)
        self.assertEqual("".join(out), "日本語のテキストをここで折り返します")

    def test_blank_lines_kept_lines_reflowed(self):
        out = w.wrap("aaa\nbbb\n\nccc", 20)
        self.assertEqual(out, ["aaa bbb", "", "ccc"])

    def test_no_line_wider_than_width_fuzz(self):
        import random
        rnd = random.Random(1)
        alphabet = ["a", "bc", "åäö", "日", "https://x.y/" + "z" * 40, " ", " "]
        for _ in range(200):
            t = "".join(rnd.choice(alphabet) for _ in range(rnd.randint(1, 60)))
            width = rnd.randint(10, 40)
            self.check_widths(w.wrap(t, width), width)


class Cli(unittest.TestCase):
    def test_width_below_10_exit_2(self):
        self.assertEqual(cli(9, "x").returncode, 2)
        self.assertEqual(cli(5, "x").returncode, 2)

    def test_not_integer_exit_2(self):
        r = subprocess.run([sys.executable, "-I", WRAP, "abc"],
                           input=b"x", capture_output=True)
        self.assertEqual(r.returncode, 2)

    def test_output(self):
        r = cli(10, "one two three four five\n")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.decode().splitlines(),
                         ["one two", "three four", "five"])

    def test_invalid_utf8_does_not_crash(self):
        r = subprocess.run([sys.executable, "-I", WRAP, "20"],
                           input=b"ok \xff\xfe bytes", capture_output=True)
        self.assertEqual(r.returncode, 0)


class KeepLines(unittest.TestCase):
    def check_widths(self, lines, width):
        for l in lines:
            self.assertLessEqual(w.vwidth(l), width, repr(l))

    def test_line_breaks_kept(self):
        self.assertEqual(w.wrap_keep_lines("aaa\nbbb\n\nccc", 20),
                         ["aaa", "bbb", "", "ccc"])

    def test_indent_and_double_space_kept(self):
        self.assertEqual(w.wrap_keep_lines("  kod  med  luft", 40),
                         ["  kod  med  luft"])

    def test_long_line_broken_at_spaces(self):
        out = w.wrap_keep_lines("one two three four five", 10)
        self.assertEqual(out, ["one two", "three four", "five"])

    def test_long_line_does_not_join_next(self):
        out = w.wrap_keep_lines("aaaa bbbbbb\ncc", 10)
        self.assertEqual(out, ["aaaa", "bbbbbb", "cc"])

    def test_swedish_widths_40_60_80(self):
        text = ("Åsa åt äpplen och öl på ön och läste en lång rad med åäö. " * 4
                + "\nKort rad med ÅÄÖ\n")
        for width in (40, 60, 80):
            out = w.wrap_keep_lines(text, width)
            self.check_widths(out, width)
            self.assertIn("Kort rad med ÅÄÖ", out)

    def test_cjk_width(self):
        out = w.wrap_keep_lines("日本語のテキストをここで折り返します\nok", 10)
        self.check_widths(out, 10)
        self.assertEqual(out[-1], "ok")

    def test_no_line_wider_than_width_fuzz(self):
        import random
        rnd = random.Random(2)
        alphabet = ["a", "bc", "åäö", "日", "https://x.y/" + "z" * 40, " ", " ", "\n"]
        for _ in range(200):
            t = "".join(rnd.choice(alphabet) for _ in range(rnd.randint(1, 60)))
            width = rnd.randint(10, 40)
            self.check_widths(w.wrap_keep_lines(t, width), width)


class KeepLinesCli(unittest.TestCase):
    def run_cli(self, args, text):
        return subprocess.run([sys.executable, "-I", WRAP] + args,
                              input=text.encode(), capture_output=True)

    def test_output(self):
        r = self.run_cli(["--keep-lines", "10"], "one two three four five\nok\n")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.decode().splitlines(),
                         ["one two", "three four", "five", "ok"])

    def test_default_still_reflows(self):
        r = self.run_cli(["10"], "one\ntwo\n")
        self.assertEqual(r.stdout.decode().splitlines(), ["one two"])

    def test_width_below_10_exit_2(self):
        self.assertEqual(self.run_cli(["--keep-lines", "9"], "x").returncode, 2)

    def test_missing_width_exit_2(self):
        self.assertEqual(self.run_cli(["--keep-lines"], "x").returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
