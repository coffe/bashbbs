# BashBBS manual: proposed structure

A new entry **Manual** in **My Account** (item 4, after Profile, SSH Keys and
Settings), linked from the ? help text and the welcome mail. It opens a numbered list; each number is one short chapter, shown
with the normal pager, `Q` goes back. Chapters are plain text, 78 columns at
most, in English. The files in this folder are the source texts (Markdown here,
stripped of markup when installed, same as the welcome mail).

Order: a one-page quick start, then what this is, then how to move around, then the parts of the BBS
in the same order as the main menu, then the two how-tos people ask about most
(files), then the rest.

| # | Chapter | File |
|---|---------|------|
| 1 | Quick start | 01-quick-start.md |
| 2 | What is a BBS? | 02-what-is-a-bbs.md |
| 3 | Getting around | 03-getting-around.md |
| 4 | Boards | 04-boards.md |
| 5 | Wall | 05-wall.md |
| 6 | News | 06-news.md |
| 7 | Fame & Glory | 07-fame-and-glory.md |
| 8 | Mail | 08-mail.md |
| 9 | My Account | 09-my-account.md |
| 10 | Games | 10-games.md |
| 11 | Files: the areas | 11-files.md |
| 12 | Downloading files | 12-downloading.md |
| 13 | Uploading files | 13-uploading.md |
| 14 | Files with scp (for terminal people) | 14-scp.md |
| 15 | Etiquette and the rules | 15-etiquette.md |

Notes for the implementation (not part of the manual):
- Chapters 12-14 replace/extend `docs/files-guide.txt`; keep one source.
  The old guide says "N" for More in the file list; the code uses Space.
- Verified against the code: 10 MB per file, 200 MB per user, 20 files per
  link, 30 min upload link, 15 min download link, sysops without size limit,
  Wall = 140 chars, N writes, Space pages.
- NOT possible as is: `menu_key` reads one key, so chapters 10-15 need a
  line prompt (type the number, Enter) or letters. Easiest: show the list in
  two pages, 1-9 by key and "N more" for 10-15.
- Link the manual from the `?` help of the main menu and add one line to
  `etc/welcome-mail.txt` once the menu exists.
- Optional: a `*` on Manual when a chapter changed since the last call.
