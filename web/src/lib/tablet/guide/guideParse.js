// Turns docs/user_guide.md into the topics the User Guide tab shows. The file format is described in the comment at the top of
// the file itself.

const CELL_SPLIT = '\u0001';

function splitRow(line) {
  return line.trim().replace(/^\|/, '').replace(/\|$/, '').replace(/\\\|/g, CELL_SPLIT).split('|').map((c) => c.split(CELL_SPLIT).join('|').trim());
}

export function parseGuide(raw) {
  const text = String(raw || '').replace(/\r\n/g, '\n').replace(/<!--[\s\S]*?-->/g, '');
  const lines = text.split('\n');
  const topics = [];
  let topic = null;
  let i = 0;

  const isSpecial = (l) => /^(#|@|>|\||- |\d+\. )/.test(l);

  while (i < lines.length) {
    const line = lines[i];

    // a new topic: "# Title", then "key: value" lines
    if (/^# /.test(line)) {
      topic = { id: '', group: 'Guide', icon: 'fileText', tag: '', title: line.slice(2).trim(), blocks: [] };
      topics.push(topic);
      i++;
      while (i < lines.length && /^(id|group|icon|tag):/.test(lines[i])) {
        const m = lines[i].match(/^(\w+):\s*(.*)$/);
        topic[m[1]] = m[2].trim();
        i++;
      }
      if (!topic.id) topic.id = topic.title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
      continue;
    }
    if (!topic || line.trim() === '') { i++; continue; }

    if (line.startsWith('## ')) { topic.blocks.push({ t: 'h', text: line.slice(3).trim() }); i++; continue; }

    if (line.trim() === '@facts') {
      const rows = [];
      i++;
      while (i < lines.length && lines[i].trim() !== '@end') {
        const idx = lines[i].indexOf(' :: ');
        if (idx > 0) rows.push([lines[i].slice(0, idx).trim(), lines[i].slice(idx + 4).trim()]);
        i++;
      }
      i++;
      topic.blocks.push({ t: 'facts', rows });
      continue;
    }

    if (line.trim() === '@cards') {
      const items = [];
      i++;
      while (i < lines.length && lines[i].trim() !== '@end') {
        const parts = lines[i].split(' | ');
        if (parts.length >= 3) items.push({ ref: parts[0].trim(), title: parts[1].trim(), text: parts.slice(2).join(' | ').trim() });
        i++;
      }
      i++;
      topic.blocks.push({ t: 'cards', items });
      continue;
    }

    // automatic blocks, filled in by the tablet from the code itself
    if (/^@(tabs|eventtypes|commands)\s*$/.test(line.trim())) {
      topic.blocks.push({ t: line.trim().slice(1) });
      i++;
      continue;
    }

    const callout = line.match(/^> (tip|warn):\s*(.*)$/);
    if (callout) { topic.blocks.push({ t: callout[1], text: callout[2].trim() }); i++; continue; }

    if (line.startsWith('|')) {
      const rows = [];
      while (i < lines.length && lines[i].startsWith('|')) { rows.push(lines[i]); i++; }
      const head = splitRow(rows[0]);
      const body = rows.slice(/^\|?[\s:|-]+\|?$/.test(rows[1] || '') ? 2 : 1).map(splitRow);
      topic.blocks.push({ t: 'table', head, rows: body });
      continue;
    }

    if (/^\d+\. /.test(line)) {
      const items = [];
      while (i < lines.length && /^\d+\. /.test(lines[i])) { items.push(lines[i].replace(/^\d+\.\s+/, '').trim()); i++; }
      topic.blocks.push({ t: 'steps', items });
      continue;
    }

    if (line.startsWith('- ')) {
      const items = [];
      while (i < lines.length && lines[i].startsWith('- ')) { items.push(lines[i].slice(2).trim()); i++; }
      topic.blocks.push({ t: 'list', items });
      continue;
    }

    // a paragraph: consecutive plain lines
    const para = [];
    while (i < lines.length && lines[i].trim() !== '' && !isSpecial(lines[i])) { para.push(lines[i].trim()); i++; }
    if (para.length) topic.blocks.push({ t: 'p', text: para.join(' ') });
    else i++;
  }
  return topics;
}

export function groupOrder(topics) {
  const out = [];
  for (const t of topics) if (!out.includes(t.group)) out.push(t.group);
  return out;
}

// every word of a topic, for the search box
export function topicText(t) {
  const parts = [t.title, t.tag];
  for (const b of t.blocks) {
    if (b.text) parts.push(b.text);
    if (b.items) parts.push(...b.items.map((x) => (typeof x === 'string' ? x : `${x.title || ''} ${x.text || ''}`)));
    if (b.rows) parts.push(...b.rows.map((r) => r.join(' ')));
    if (b.head) parts.push(b.head.join(' '));
  }
  return parts.join(' ').toLowerCase();
}
