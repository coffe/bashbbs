#!/usr/bin/env python3
"""Turn docs/manual/NN-*.md into plain-text etc/manual/NN.txt (markup stripped).
Line 1 of each output is the chapter title; the pager shows the rest."""
import glob, os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, '..', 'etc', 'manual')
os.makedirs(out, exist_ok=True)
for src in sorted(glob.glob(os.path.join(here, 'manual', '[0-9][0-9]-*.md'))):
    n = os.path.basename(src)[:2]
    if n == '00':
        continue
    lines = open(src, encoding='utf-8').read().splitlines()
    m = re.match(r'#\s*\d+\.\s*(.*)', lines[0])
    title = m.group(1)
    body = []
    for l in lines[1:]:
        l = re.sub(r'\*\*(.+?)\*\*', r'\1', l)
        l = re.sub(r'`([^`]*)`', r'\1', l)
        if l.startswith('## '):
            l = l[3:].upper()
        body.append(l)
    while body and not body[0].strip():
        body.pop(0)
    for l in body:
        if len(l) > 78:
            sys.exit(f'{src}: line over 78 columns: {l}')
    open(os.path.join(out, n + '.txt'), 'w', encoding='utf-8').write(title + '\n' + '\n'.join(body) + '\n')
