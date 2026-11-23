# News: the producer interface

How news reaches the BBS. This is the contract for the news producer, which lives in
a separate private repository. Everything here is the Pi side, in this repository.

## Flow

1. The producer sends one article per SSH call:
   `ssh bbs-news@<pi> < article.post`
   - The `bbs-news` account allows key login only. `ForceCommand /usr/local/sbin/bbs-ingest`
     applies, with no pty and no forwarding (`etc/sshd-bashbbs.conf`).
   - `bbs-ingest` reads at most 16384 bytes from stdin. It writes the file to
     `/srv/bashbbs/queue/incoming/<epoch>-<uuid>.post` and answers `queued`.
   - `queued` only means the article is in the queue. It is not published yet.
2. `bbs-publish` runs every 60 seconds (`bbs-publish.timer`). It checks each `.post`
   owned by `bbs-news` that has `Board: news`.
   - Accepted: the article moves to `boards/news/<category>/<epoch>-<msgid>.msg`. It is
     added to the index `state/news-index.tsv` and to the ledger `state/news-ids.tsv`
     as `published`.
   - Rejected: the file moves to `drop/rejected/`, and the ledger records `rejected`
     with a reason.
   - Temporary failure (lock busy and similar): the file stays and is tried again.
     After 24 hours it is recorded as `rejected` with the reason `stale`.
3. The producer asks for status on a separate channel:
   `printf '%s\n' <id> ... | ssh newsstatus@<pi>`
   - `ForceCommand bbs-news-status` is read-only and takes at most 200 ids per call.
   - The answer is one line per id: `<id>\t<published|rejected|unknown>\t<reason>`.
     An invalid id gives `-\tinvalid\tbad-id`.
4. `bbs-drop` runs every 5 minutes. It deletes articles older than 14 days, and their
   index rows.

## File format (`.post`)

`Name: value` header lines, then a blank line, then the body. Everything is UTF-8.

```
Board: news
Category: security
Article-Id: <64 lowercase hex characters>
Subject: Headline, at most 100 characters (longer is cut)
Source: Source name, at most 60 characters
Published: 2026-11-22T20:30:00Z
Link: https://example.com/article
Lede: Lead paragraph, at most 200 characters
Original-Language: en

Body text, at most 11000 bytes.
```

Rules, from `handle_news_post` in `sbin/bbs-publish`:

- **Required:** `Board: news`, `Category`, `Article-Id`, `Subject`, `Source`, `Published`.
- **Optional:** `Link`, `Lede`, `Original-Language` (2–3 lowercase letters, ISO 639).
- **`Category`:** one of the names in `lib/news-categories.conf`: `ai`, `security`,
  `tech-society`, `games-anime`, `comics`, `events`, `did-you-know`, `new-nodes`, `other`.
- **`Article-Id`:** `^[0-9a-f]{64}$`, for example sha256 of the canonical link. It is
  the duplicate key: the same id sent twice is published once, and the second send
  counts as a success. Never resend an id whose status is `published`.
- **`Published`:** exactly `YYYY-MM-DDTHH:MM:SSZ`, UTC, and a valid date.
- **`Link`:** `http(s)://`, no whitespace, at most 300 bytes. Tracking parameters
  (`utm_*`, `fbclid` and others) are removed.
- **Header:** each name at most once. No control characters (CR, ESC, NUL). Every line
  has the form `Name: value`.
- **Size:** the whole file at most 16384 bytes, the body at most 11000 bytes.
  Control characters in the body are removed. No markup is rendered: write plain text.
  The BBS shows it in a terminal, often 40–80 columns wide, and wraps it itself.

Reject reasons: `too-large`, `bad-headers`, `bad-category`, `bad-id`, `bad-link`,
`bad-board`, `stale`.

## Recommended producer behaviour

- Send one article per SSH call and wait for `queued`.
- Check status with `newsstatus` no sooner than 1–2 minutes later, because the publish
  timer runs every 60 seconds.
- Resend only on `unknown`, which means the article never reached the ledger. Never
  resend on `rejected`: fix the cause the reason points to first.
- Readers are told that news updates a few times a day (manual, chapter 6). Frequent
  runs are not needed.
- Articles are kept for 14 days. Older news is not worth sending.

## Manual route

Drop `<category>-<slug>.txt` in `/srv/bashbbs/drop/news/`. The first line is the title,
then a blank line, then the body. `bbs-drop` queues it as `bbs-news`. This route is for
the sysop, not for the producer.
