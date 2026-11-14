# 14. Files with scp (for terminal people)

Normal transfers use web links (chapters 12 and 13). If you live in a shell,
scp is an alternative that skips the browser. The Files menu (press O)
shows the exact commands with your own login, host and port.

Use scp -O, the old protocol. Plain scp and sftp do not work here.

  Upload:    scp -O -P PORT FILE LOGIN@HOST:
  Download:  scp -O -P PORT LOGIN@HOST:NAME .

Notes:
- Files sent with scp land in the General area. Move them with M and add a
  description with E and tags with T in the menu.
- If an scp upload fails, nothing from it is saved and the reason is not
  shown. Use the web link when you want to see why.
- The same limits and checks apply as for web uploads (chapter 13).
