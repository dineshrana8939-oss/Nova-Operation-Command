// ─── Auto-generated catalog of 41 extra minigames ───
export const extraGames = {};

const MG = {
  register(id, def) {
    extraGames[id] = def;
  }
};

// ── animus.js ──
MG.register('animus', {
    title: 'Animus',
    hint: 'Click a ring to rotate · align all key segments to the line',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const ringCount = 2 + Math.floor(diff / 1.3);
        const segs = 6 + (diff >= 3 ? 2 : 0);
        const W = 320, H = 320, cx = W / 2, cy = H / 2;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const guideSeg = 0;
        const rings = [];
        for (let i = 0; i < ringCount; i++) {
            rings.push({
                rIn: 40 + i * 32,
                rOut: 40 + i * 32 + 26,
                key: api.randInt(0, segs - 1),
                offset: api.randInt(1, segs - 1)
            });
        }

        let solved = false;
        function rel(e) {
            const b = cvs.getBoundingClientRect();
            const x = (e.clientX - b.left) * (cvs.width / b.width) - cx;
            const y = (e.clientY - b.top) * (cvs.height / b.height) - cy;
            return Math.hypot(x, y);
        }
        cvs.addEventListener('click', (e) => {
            if (solved) return;
            const dist = rel(e);
            const ring = rings.find((r) => dist >= r.rIn - 6 && dist <= r.rOut + 6);
            if (!ring) return;
            ring.offset = (ring.offset + 1) % segs;
            checkSolved();
        });
        function checkSolved() {
            const ok = rings.every((r) => (r.key + r.offset) % segs === guideSeg);
            if (ok) {
                solved = true; api.stopTimer(); api.setTag('SYNCHRONIZED');
                setTimeout(() => api.succeed(), 450);
            }
        }

        api.setTag('DESYNCED');
        api.startTimer(Math.max(16, 34 - diff * 2), () => { if (!solved) api.fail(); });

        function draw() {
            ctx.clearRect(0, 0, W, H);
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            const segAng = (Math.PI * 2) / segs;
            const guideAngle = -Math.PI / 2;

            ctx.strokeStyle = solved ? suc : acc; ctx.lineWidth = 2;
            ctx.shadowColor = solved ? suc : acc; ctx.shadowBlur = 10;
            ctx.beginPath();
            ctx.moveTo(cx + Math.cos(guideAngle) * 30, cy + Math.sin(guideAngle) * 30);
            ctx.lineTo(cx + Math.cos(guideAngle) * (rings[ringCount - 1].rOut + 14),
                       cy + Math.sin(guideAngle) * (rings[ringCount - 1].rOut + 14));
            ctx.stroke(); ctx.shadowBlur = 0;

            rings.forEach((ring) => {
                for (let s = 0; s < segs; s++) {
                    const isKey = (s === (ring.key + ring.offset) % segs);
                    const a0 = guideAngle - segAng / 2 + s * segAng;
                    const a1 = a0 + segAng * 0.86;
                    const aligned = isKey && (((ring.key + ring.offset) % segs) === guideSeg);
                    ctx.beginPath();
                    ctx.arc(cx, cy, ring.rOut, a0, a1);
                    ctx.arc(cx, cy, ring.rIn, a1, a0, true);
                    ctx.closePath();
                    if (isKey) {
                        ctx.fillStyle = aligned ? suc : acc;
                        ctx.shadowColor = aligned ? suc : acc; ctx.shadowBlur = 14;
                    } else {
                        ctx.fillStyle = 'rgba(255,255,255,0.07)';
                        ctx.shadowBlur = 0;
                    }
                    ctx.fill();
                    ctx.shadowBlur = 0;
                    ctx.strokeStyle = 'rgba(0,0,0,0.5)'; ctx.lineWidth = 1; ctx.stroke();
                }
            });
            ctx.fillStyle = solved ? suc : '#1a2230';
            ctx.beginPath(); ctx.arc(cx, cy, 26, 0, Math.PI * 2); ctx.fill();
            ctx.strokeStyle = acc; ctx.lineWidth = 2; ctx.stroke();

            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── beltsort.js ──
MG.register('beltsort', {
    title: 'Quality Control',
    hint: 'Click the cracked (red) parts before they leave the belt · let good ones pass',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 440, H = 280;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const need = 5 + diff;
        const maxWrong = Math.max(2, 5 - diff);
        const speed = 1.1 + diff * 0.4;
        const spawnGap = Math.max(34, 72 - diff * 8);
        const beltY = H / 2, R = 16;
        let parts = [], caught = 0, wrong = 0, frame = 0, done = false, dash = 0;

        api.setDots(maxWrong);
        function strike() { wrong++; api.setDots(maxWrong, Array.from({ length: maxWrong }, (_, i) => i < wrong ? 'fail' : '')); if (wrong >= maxWrong) finish(false); }
        function finish(ok) { if (done) return; done = true; api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 250); }

        cvs.addEventListener('click', (e) => {
            if (done) return;
            const b = cvs.getBoundingClientRect();
            const x = (e.clientX - b.left) * (W / b.width), y = (e.clientY - b.top) * (H / b.height);
            for (let i = parts.length - 1; i >= 0; i--) {
                const p = parts[i];
                if (!p.gone && Math.hypot(x - p.x, y - beltY) < R + 4) {
                    p.gone = true;
                    if (p.def) { caught++; api.sfx('zap'); api.setTag(caught + '/' + need); if (caught >= need) finish(true); }
                    else { api.shake(); strike(); }
                    return;
                }
            }
        });

        api.setTag('0/' + need);
        api.startTimer(Math.max(20, 34 - diff * 2), () => finish(caught >= need));

        function gear(x, y, r, col, def) {
            ctx.strokeStyle = col; ctx.fillStyle = col; ctx.lineWidth = 3; ctx.lineCap = 'round';
            ctx.shadowColor = col; ctx.shadowBlur = 8;
            ctx.beginPath(); ctx.arc(x, y, r * 0.62, 0, Math.PI * 2); ctx.stroke();
            for (let k = 0; k < 8; k++) { const a = k * Math.PI / 4; ctx.beginPath(); ctx.moveTo(x + Math.cos(a) * r * 0.62, y + Math.sin(a) * r * 0.62); ctx.lineTo(x + Math.cos(a) * r, y + Math.sin(a) * r); ctx.stroke(); }
            ctx.shadowBlur = 0;
            ctx.beginPath(); ctx.arc(x, y, r * 0.2, 0, Math.PI * 2); ctx.stroke();
            if (def) { ctx.lineWidth = 2.5; ctx.beginPath(); ctx.moveTo(x - r * 0.4, y - r * 0.3); ctx.lineTo(x + r * 0.05, y + r * 0.1); ctx.lineTo(x - r * 0.15, y + r * 0.35); ctx.stroke(); }
        }

        function draw() {
            frame++;
            if (!done && frame % spawnGap === 0) parts.push({ x: -R, def: Math.random() < 0.5, gone: false });
            if (!done) dash = (dash + speed) % 28;
            ctx.clearRect(0, 0, W, H);

            // belt
            ctx.fillStyle = 'rgba(255,255,255,0.04)'; ctx.fillRect(0, beltY - R - 10, W, (R + 10) * 2);
            ctx.strokeStyle = 'rgba(255,255,255,0.15)'; ctx.lineWidth = 2;
            ctx.beginPath(); ctx.moveTo(0, beltY - R - 10); ctx.lineTo(W, beltY - R - 10); ctx.moveTo(0, beltY + R + 10); ctx.lineTo(W, beltY + R + 10); ctx.stroke();
            ctx.strokeStyle = 'rgba(255,255,255,0.1)'; ctx.lineWidth = 2;
            for (let x = -28 + dash; x < W; x += 28) { ctx.beginPath(); ctx.moveTo(x, beltY + R + 10); ctx.lineTo(x + 14, beltY + R + 10); ctx.stroke(); }

            parts.forEach(p => {
                if (p.gone) return;
                if (!done) p.x += speed;
                if (p.x > W + R) { p.gone = true; if (p.def) strike(); return; }
                gear(p.x, beltY, R, p.def ? dng : acc, p.def);
            });
            parts = parts.filter(p => !p.gone);

            ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '11px monospace'; ctx.textAlign = 'center';
            ctx.fillText('PULL THE CRACKED PARTS · ' + caught + ' / ' + need, W / 2, 22);
            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── bluff.js ──
MG.register('bluff', {
    title: 'Bluff',
    hint: 'Read the tell · CALL a bluff, FOLD on truth',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const hands = api.cfg.hands || 3;
        const readTime = Math.max(2.2, 5 - diff * 0.5);

        const tells = [
            { face: '😬', text: 'forced grin, eyes flick away', bluff: true },
            { face: '😐', text: 'flat, steady gaze', bluff: false },
            { face: '😅', text: 'beads of sweat, quick swallow', bluff: true },
            { face: '🙂', text: 'relaxed jaw, slow blink', bluff: false },
            { face: '😶', text: 'frozen still — too still', bluff: true },
            { face: '😏', text: 'calm smirk, even breathing', bluff: false }
        ];

        let hand = 0, correct = 0, current = null, timeout = null;
        api.setDots(hands);

        const box = document.createElement('div');
        box.style.cssText = 'width:420px;display:flex;flex-direction:column;align-items:center;gap:18px;';
        box.innerHTML = `
            <div id="face" style="font-size:84px;line-height:1;filter:drop-shadow(0 0 20px var(--accent));"></div>
            <div id="tell" style="font-family:var(--display);font-size:15px;color:var(--muted);min-height:22px;"></div>
            <div id="meter" style="width:100%;height:8px;border-radius:4px;background:rgba(255,255,255,.08);overflow:hidden;">
                <div id="mfill" style="height:100%;width:50%;background:var(--accent);transition:width .1s;"></div>
            </div>
            <div style="display:flex;gap:14px;margin-top:6px;">
                <button class="btn danger" id="call">CALL BLUFF</button>
                <button class="btn" id="fold">FOLD</button>
            </div>`;
        api.board.appendChild(box);
        const faceEl = box.querySelector('#face');
        const tellEl = box.querySelector('#tell');
        const mfill  = box.querySelector('#mfill');

        function nextHand() {
            if (hand >= hands) { finish(); return; }
            current = tells[api.randInt(0, tells.length - 1)];
            faceEl.textContent = current.face;
            tellEl.textContent = current.text;
            api.setTag('HAND ' + (hand + 1) + '/' + hands);
            let p = 0.5;
            clearInterval(box._wob);
            box._wob = setInterval(() => {
                p += (Math.random() - 0.5) * (0.1 + diff * 0.04);
                p = Math.max(0.05, Math.min(0.95, p));
                mfill.style.width = (p * 100) + '%';
            }, 80);
            clearTimeout(timeout);
            timeout = setTimeout(() => decide(null), readTime * 1000);
        }

        function decide(choice) {
            clearTimeout(timeout);
            clearInterval(box._wob);
            if (!current) return;
            const right = (choice === 'call' && current.bluff) ||
                          (choice === 'fold' && !current.bluff);
            if (right) correct++;
            const st = [];
            for (let i = 0; i < hands; i++) {
                st[i] = i < hand ? (i < correct ? 'done' : 'fail') : (i === hand ? 'active' : '');
            }
            if (!right) api.shake();
            hand++;
            redrawDots();
            setTimeout(nextHand, 350);
        }

        function redrawDots() {
            const st = [];
            let c = correct, wrong = hand - correct, ci = 0;
            for (let i = 0; i < hands; i++) {
                if (i < hand) { st[i] = (i < correct) ? 'done' : 'fail'; }
                else st[i] = (i === hand) ? 'active' : '';
            }
            api.setDots(hands, st);
        }

        function finish() {
            const pass = correct >= Math.ceil(hands / 2 + (diff >= 4 ? 0.5 : 0));
            api.stopTimer();
            setTimeout(() => pass ? api.succeed() : api.fail(), 200);
        }

        box.querySelector('#call').onclick = () => decide('call');
        box.querySelector('#fold').onclick = () => decide('fold');

        api.startTimer(readTime * hands + 2, () => { /* overall guard */ finish(); });
        nextHand();

        return { destroy() { clearTimeout(timeout); clearInterval(box._wob); } };
    }
});

// ── bonepin.js ──
MG.register('bonepin', {
    title: 'Bone Set',
    hint: 'Drag each fragment onto its matching slot',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 400, H = 280;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'grab';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();

        const N = 2 + Math.floor(diff / 1.5); // 2..5
        const tol = Math.max(12, 30 - diff * 3);
        const slotY = H / 2 - 22;
        const pieces = [];
        for (let i = 0; i < N; i++) {
            const sx = 70 + (W - 140) * ((i + 0.5) / N);
            pieces.push({ sx, sy: slotY, x: 60 + Math.random() * (W - 120), y: H - 58 + Math.random() * 28, w: (W - 140) / N - 8, rot: api.rand(-0.3, 0.3), placed: false });
        }
        let drag = null, off = { x: 0, y: 0 }, placedN = 0, done = false;

        api.setDots(N);
        function rel(e) { const b = cvs.getBoundingClientRect(); return { x: (e.clientX - b.left) * (W / b.width), y: (e.clientY - b.top) * (H / b.height) }; }
        function at(cx, cy) { for (let i = pieces.length - 1; i >= 0; i--) { const p = pieces[i]; if (!p.placed && Math.abs(cx - p.x) < p.w / 2 + 6 && Math.abs(cy - p.y) < 16) return p; } return null; }

        cvs.addEventListener('mousedown', (e) => { const r = rel(e); const p = at(r.x, r.y); if (p) { drag = p; off.x = r.x - p.x; off.y = r.y - p.y; cvs.style.cursor = 'grabbing'; } });
        cvs.addEventListener('mousemove', (e) => { if (!drag) return; const r = rel(e); drag.x = r.x - off.x; drag.y = r.y - off.y; });
        function dropPiece() {
            if (!drag) return; const p = drag; drag = null; cvs.style.cursor = 'grab';
            if (Math.hypot(p.x - p.sx, p.y - p.sy) < tol) {
                p.placed = true; p.x = p.sx; p.y = p.sy; p.rot = 0; placedN++; api.sfx('latch');
                api.setDots(N, pieces.map(pp => pp.placed ? 'done' : ''));
                if (placedN >= N) { done = true; api.stopTimer(); api.setTag('SET'); setTimeout(() => api.succeed(), 300); }
            } else api.sfx('tick');
        }
        cvs.addEventListener('mouseup', dropPiece);
        cvs.addEventListener('mouseleave', dropPiece);

        api.setTag('ALIGNING');
        api.startTimer(Math.max(16, 30 - diff * 2), () => { if (!done) { done = true; api.stopTimer(); setTimeout(() => api.fail(), 200); } });

        function frag(x, y, w, rot, col, alpha) {
            ctx.save(); ctx.globalAlpha = alpha == null ? 1 : alpha; ctx.translate(x, y); ctx.rotate(rot);
            const hw = w / 2;
            ctx.fillStyle = col; ctx.beginPath();
            ctx.moveTo(-hw, -8); ctx.lineTo(hw, -8); ctx.arc(hw, 0, 8, -Math.PI / 2, Math.PI / 2); ctx.lineTo(-hw, 8); ctx.arc(-hw, 0, 8, Math.PI / 2, -Math.PI / 2); ctx.closePath(); ctx.fill();
            ctx.restore(); ctx.globalAlpha = 1;
        }

        function draw() {
            ctx.clearRect(0, 0, W, H);
            pieces.forEach(p => { if (!p.placed) { frag(p.sx, p.sy, p.w, 0, 'rgba(255,255,255,0.5)', 0.22); ctx.setLineDash([4, 4]); ctx.strokeStyle = 'rgba(255,255,255,0.3)'; ctx.strokeRect(p.sx - p.w / 2, p.sy - 12, p.w, 24); ctx.setLineDash([]); } });
            pieces.forEach(p => { const near = !p.placed && Math.hypot(p.x - p.sx, p.y - p.sy) < tol; frag(p.x, p.y, p.w, p.placed ? 0 : p.rot, (p.placed || near) ? suc : acc); });
            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── breathalyzer.js ──
MG.register('breathalyzer', {
    title: 'Breathalyzer',
    hint: 'Hold SPACE / mouse to blow · keep the flow in the green to log a reading',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 360, H = 280;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const bandH = Math.max(0.16, 0.34 - diff * 0.03);
        const lo = 0.48, hi = lo + bandH;
        const rise = 0.95, drain = 0.85, fillRate = 0.32;
        let flow = 0, reading = 0, hold = false, done = false, last = performance.now();

        function down(e) { if (e.code === 'Space') { e.preventDefault(); hold = true; } }
        function up(e) { if (e.code === 'Space') { e.preventDefault(); hold = false; } }
        document.addEventListener('keydown', down);
        document.addEventListener('keyup', up);
        cvs.addEventListener('mousedown', () => hold = true);
        cvs.addEventListener('mouseup', () => hold = false);
        cvs.addEventListener('mouseleave', () => hold = false);

        api.setTag('BLOW');
        api.startTimer(Math.max(16, 26 - diff * 2), () => fail());
        function clean() { document.removeEventListener('keydown', down); document.removeEventListener('keyup', up); }
        function fail() { if (done) return; done = true; clean(); api.stopTimer(); api.shake(); setTimeout(() => api.fail(), 200); }
        function win() { if (done) return; done = true; clean(); api.stopTimer(); api.setTag('READING LOGGED'); setTimeout(() => api.succeed(), 300); }

        function draw() {
            const now = performance.now(); const dt = Math.min(0.05, (now - last) / 1000); last = now;
            if (!done) {
                flow = Math.max(0, Math.min(1, flow + (hold ? rise : -drain) * dt));
                const inB = flow >= lo && flow <= hi;
                reading = Math.max(0, Math.min(1, reading + (inB ? fillRate : -fillRate * 0.5) * dt));
                if (reading >= 1) { win(); return; }
            }
            ctx.clearRect(0, 0, W, H);

            // flow gauge (vertical)
            const gx = 90, gw = 54, top = 30, bh = H - 80;
            ctx.fillStyle = 'rgba(255,255,255,0.07)'; ctx.fillRect(gx, top, gw, bh);
            ctx.fillStyle = 'rgba(57,217,138,0.18)'; ctx.fillRect(gx, top + bh * (1 - hi), gw, bh * (hi - lo));
            ctx.strokeStyle = 'rgba(57,217,138,0.5)'; ctx.lineWidth = 1; ctx.strokeRect(gx, top + bh * (1 - hi), gw, bh * (hi - lo));
            const inB = flow >= lo && flow <= hi;
            const fy = top + bh * (1 - flow);
            ctx.fillStyle = inB ? suc : dng; ctx.shadowColor = inB ? suc : dng; ctx.shadowBlur = 12;
            ctx.fillRect(gx - 4, fy - 3, gw + 8, 6); ctx.shadowBlur = 0;
            ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '10px monospace'; ctx.textAlign = 'center'; ctx.fillText('FLOW', gx + gw / 2, H - 38);

            // device + reading bar
            const dxc = 230;
            ctx.strokeStyle = 'rgba(255,255,255,0.2)'; ctx.lineWidth = 2;
            ctx.strokeRect(dxc - 36, 60, 72, 120);
            ctx.fillStyle = inB ? 'rgba(57,217,138,0.12)' : 'rgba(255,255,255,0.03)'; ctx.fillRect(dxc - 36, 60, 72, 120);
            ctx.fillStyle = '#fff'; ctx.font = 'bold 22px monospace'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
            ctx.fillText(Math.round(reading * 100) + '%', dxc, 120);
            ctx.textBaseline = 'alphabetic';
            ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(dxc - 36, 196, 72, 10);
            ctx.fillStyle = suc; ctx.fillRect(dxc - 36, 196, 72 * reading, 10);
            ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '10px monospace'; ctx.fillText('READING', dxc, 224);

            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); clean(); } };
    }
});

// ── cashcount.js ──
MG.register('cashcount', {
    title: 'Count The Take',
    hint: 'Click bills to hit the exact amount · UNDO to remove the last',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 420, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const DENOMS = [5, 10, 20, 50, 100];
        const target = 5 * api.randInt(15 + diff * 6, 35 + diff * 22);
        let total = 0, stack = [], done = false, flash = 0;

        const bw = (W - 50) / (DENOMS.length + 1);
        const btns = DENOMS.map((d, i) => ({ d, x: 25 + i * bw, w: bw - 8, y: H - 78, h: 52 }));
        const undoBtn = { x: 25 + DENOMS.length * bw, w: bw - 8, y: H - 78, h: 52 };

        function check() { api.setTag('$' + total + ' / $' + target); if (total === target) { done = true; api.stopTimer(); api.setTag('EXACT — $' + total); setTimeout(() => api.succeed(), 350); } }
        function add(d) { if (done) return; total += d; stack.push(d); flash = 6; api.sfx('click'); check(); }
        function undo() { if (done || !stack.length) return; total -= stack.pop(); api.sfx('tick'); }

        cvs.addEventListener('click', (e) => {
            if (done) return;
            const b = cvs.getBoundingClientRect();
            const x = (e.clientX - b.left) * (W / b.width), y = (e.clientY - b.top) * (H / b.height);
            for (const bt of btns) if (x >= bt.x && x <= bt.x + bt.w && y >= bt.y && y <= bt.y + bt.h) { add(bt.d); return; }
            if (x >= undoBtn.x && x <= undoBtn.x + undoBtn.w && y >= undoBtn.y && y <= undoBtn.y + undoBtn.h) undo();
        });

        api.setTag('$0 / $' + target);
        api.startTimer(Math.max(20, 34 - diff * 2), () => { if (!done) { done = true; api.stopTimer(); setTimeout(() => api.fail(), 200); } });

        function rr(x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }

        function draw() {
            if (flash > 0) flash--;
            ctx.clearRect(0, 0, W, H);

            const over = total > target;
            ctx.fillStyle = 'rgba(255,255,255,0.4)'; ctx.font = '11px monospace'; ctx.textAlign = 'center'; ctx.fillText('TARGET', W / 2, 36);
            ctx.fillStyle = '#fff'; ctx.font = 'bold 38px monospace'; ctx.fillText('$' + target.toLocaleString(), W / 2, 78);

            ctx.fillStyle = over ? dng : (total === target ? suc : acc);
            ctx.font = 'bold 26px monospace'; ctx.shadowColor = ctx.fillStyle; ctx.shadowBlur = flash * 3;
            ctx.fillText('$' + total.toLocaleString(), W / 2, 124); ctx.shadowBlur = 0;
            ctx.fillStyle = over ? dng : 'rgba(255,255,255,0.4)'; ctx.font = '11px monospace';
            ctx.fillText(over ? 'OVER — undo some' : (target - total) + ' to go  ·  ' + stack.length + ' bills', W / 2, 146);

            btns.forEach(bt => {
                ctx.fillStyle = 'rgba(57,217,138,0.10)'; rr(bt.x, bt.y, bt.w, bt.h, 7); ctx.fill();
                ctx.strokeStyle = suc; ctx.lineWidth = 1.5; rr(bt.x, bt.y, bt.w, bt.h, 7); ctx.stroke();
                ctx.fillStyle = suc; ctx.font = 'bold 16px monospace'; ctx.textAlign = 'center'; ctx.fillText('$' + bt.d, bt.x + bt.w / 2, bt.y + bt.h / 2 + 5);
            });
            ctx.fillStyle = 'rgba(255,59,92,0.10)'; rr(undoBtn.x, undoBtn.y, undoBtn.w, undoBtn.h, 7); ctx.fill();
            ctx.strokeStyle = dng; ctx.lineWidth = 1.5; rr(undoBtn.x, undoBtn.y, undoBtn.w, undoBtn.h, 7); ctx.stroke();
            ctx.fillStyle = dng; ctx.font = 'bold 12px monospace'; ctx.fillText('UNDO', undoBtn.x + undoBtn.w / 2, undoBtn.y + undoBtn.h / 2 + 4);

            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── chopshop.js ──
MG.register('chopshop', {
    title: 'Chop Shop',
    hint: 'Press & hold on each part to unbolt it · strip the car before the heat maxes',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 440, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const n = 4 + Math.floor(diff / 1.5);
        const heatRate = 0.035 + diff * 0.012;
        const unbolt = 0.55 + diff * 0.12;
        const carX = 80, carY = 96, carW = 280, carH = 96;
        const spots = [
            { x: carX + 56, y: carY + carH, lbl: 'wheel' },
            { x: carX + carW - 56, y: carY + carH, lbl: 'wheel' },
            { x: carX + 44, y: carY + 30, lbl: 'hood' },
            { x: carX + carW - 44, y: carY + 26, lbl: 'trunk' },
            { x: carX + carW / 2 - 30, y: carY + 8, lbl: 'roof' },
            { x: carX + carW / 2 + 36, y: carY + carH - 26, lbl: 'door' },
            { x: carX + 14, y: carY + carH - 30, lbl: 'light' }
        ];
        const parts = spots.slice(0, n).map(s => ({ x: s.x, y: s.y, r: 15, prog: 0, done: false }));
        let heat = 0, stripped = 0, done = false, down = false, mx = 0, my = 0, last = performance.now();

        api.setDots(n);
        function rel(e) { const b = cvs.getBoundingClientRect(); mx = (e.clientX - b.left) * (W / b.width); my = (e.clientY - b.top) * (H / b.height); }
        cvs.addEventListener('mousedown', (e) => { rel(e); down = true; });
        cvs.addEventListener('mousemove', rel);
        cvs.addEventListener('mouseup', () => down = false);
        cvs.addEventListener('mouseleave', () => down = false);

        api.setTag('STRIP IT');
        api.startTimer(60, () => { });
        function fail() { if (done) return; done = true; api.stopTimer(); api.shake(); setTimeout(() => api.fail(), 200); }
        function win() { if (done) return; done = true; api.stopTimer(); api.setTag('STRIPPED'); setTimeout(() => api.succeed(), 300); }

        function draw() {
            const now = performance.now(); const dt = Math.min(0.05, (now - last) / 1000); last = now;
            let onPart = null;
            if (!done) {
                if (down) for (const p of parts) if (!p.done && Math.hypot(mx - p.x, my - p.y) < p.r + 4) { onPart = p; break; }
                parts.forEach(p => {
                    if (p.done) return;
                    if (p === onPart) { p.prog += dt / unbolt; if (p.prog >= 1) { p.done = true; stripped++; api.sfx('latch'); api.setDots(n, parts.map(q => q.done ? 'done' : '')); if (stripped >= n) { win(); } } }
                    else p.prog = Math.max(0, p.prog - dt * 1.5);
                });
                heat = Math.min(1, heat + heatRate * dt);
                if (heat >= 1) { fail(); return; }
            }
            ctx.clearRect(0, 0, W, H);

            // car body
            ctx.fillStyle = 'rgba(255,255,255,0.05)';
            ctx.beginPath(); ctx.moveTo(carX, carY + carH); ctx.lineTo(carX + 30, carY + 18); ctx.lineTo(carX + carW - 50, carY + 18); ctx.lineTo(carX + carW, carY + carH); ctx.closePath(); ctx.fill();
            ctx.fillStyle = 'rgba(255,255,255,0.04)'; ctx.fillRect(carX + 60, carY + 24, carW - 130, 26);
            ctx.strokeStyle = 'rgba(255,255,255,0.1)'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(carX, carY + carH); ctx.lineTo(carX + 30, carY + 18); ctx.lineTo(carX + carW - 50, carY + 18); ctx.lineTo(carX + carW, carY + carH); ctx.stroke();

            // parts
            parts.forEach(p => {
                if (p.done) { ctx.strokeStyle = 'rgba(255,255,255,0.12)'; ctx.lineWidth = 1; ctx.setLineDash([3, 3]); ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2); ctx.stroke(); ctx.setLineDash([]); return; }
                ctx.fillStyle = 'rgba(0,224,184,0.12)'; ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2); ctx.fill();
                ctx.strokeStyle = acc; ctx.lineWidth = 2; ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2); ctx.stroke();
                // bolt cross
                ctx.strokeStyle = acc; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(p.x - 5, p.y); ctx.lineTo(p.x + 5, p.y); ctx.moveTo(p.x, p.y - 5); ctx.lineTo(p.x, p.y + 5); ctx.stroke();
                if (p.prog > 0) { ctx.strokeStyle = suc; ctx.lineWidth = 3; ctx.beginPath(); ctx.arc(p.x, p.y, p.r + 4, -Math.PI / 2, -Math.PI / 2 + p.prog * Math.PI * 2); ctx.stroke(); }
            });

            // heat bar
            ctx.fillStyle = 'rgba(255,255,255,0.45)'; ctx.font = '11px monospace'; ctx.textAlign = 'center'; ctx.fillText('STRIPPED ' + stripped + ' / ' + n, W / 2, 28);
            ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(40, H - 24, W - 80, 10);
            ctx.fillStyle = heat > 0.7 ? dng : 'rgba(255,140,0,0.85)'; ctx.fillRect(40, H - 24, (W - 80) * heat, 10);
            ctx.fillStyle = heat > 0.7 ? dng : 'rgba(255,255,255,0.5)'; ctx.font = '9px monospace'; ctx.textAlign = 'left'; ctx.fillText('HEAT — cops incoming', 40, H - 28);

            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── cooking.js ──
MG.register('cooking', {
    title: 'Cooking',
    hint: 'Hit SPACE when the marker is in the green for each step',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const steps = 3 + Math.floor(diff / 1.3);
        const W = 420, H = 220;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const STEP_NAMES = ['CHOP', 'SEAR', 'SEASON', 'STIR', 'PLATE', 'GARNISH'];
        const zoneW = Math.max(44, 130 - diff * 14);
        const speed = 1.6 + diff * 0.8;

        let step = 0, ended = false, pos = 60, dir = 1;
        let zoneX = newZone();
        api.setDots(steps);

        function newZone() { return 70 + Math.random() * (W - 140 - zoneW); }

        function attempt() {
            if (ended) return;
            const inside = pos >= zoneX && pos <= zoneX + zoneW;
            if (inside) {
                step++;
                api.sfx('step');
                api.setDots(steps, Array.from({ length: steps }, (_, i) => i < step ? 'done' : ''));
                if (step >= steps) { finish(true); return; }
                zoneX = newZone(); dir = Math.random() < 0.5 ? 1 : -1;
            } else { finish(false); }
        }
        function key(e) { if (e.code === 'Space') { e.preventDefault(); attempt(); } }
        document.addEventListener('keydown', key);
        cvs.addEventListener('click', attempt);

        api.startTimer(Math.max(11, 24 - diff * 1.6), () => finish(false));
        function finish(ok) { if (ended) return; ended = true; if (!ok) api.shake(); document.removeEventListener('keydown', key); api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 200); }

        function draw() {
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            if (!ended) {
                pos += dir * speed;
                if (pos > W - 60) { pos = W - 60; dir = -1; }
                if (pos < 60) { pos = 60; dir = 1; }
            }
            ctx.clearRect(0, 0, W, H);
            api.setTag(STEP_NAMES[step % STEP_NAMES.length] + ' (' + (step + 1) + '/' + steps + ')');

            const trackY = H / 2;
            ctx.fillStyle = 'rgba(255,255,255,0.08)';
            ctx.fillRect(50, trackY - 24, W - 100, 48);
            ctx.fillStyle = 'rgba(57,217,138,0.18)';
            ctx.strokeStyle = suc; ctx.lineWidth = 2;
            ctx.fillRect(zoneX, trackY - 24, zoneW, 48);
            ctx.strokeRect(zoneX, trackY - 24, zoneW, 48);
            ctx.strokeStyle = '#fff'; ctx.lineWidth = 3; ctx.shadowColor = acc; ctx.shadowBlur = 12;
            ctx.beginPath(); ctx.moveTo(pos, trackY - 32); ctx.lineTo(pos, trackY + 32); ctx.stroke(); ctx.shadowBlur = 0;

            ctx.fillStyle = 'rgba(255,255,255,0.4)'; ctx.font = '12px monospace'; ctx.textAlign = 'center';
            ctx.fillText('SPACE in the green', W / 2, trackY + 60);
            if (!ended) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); } };
    }
});

// ── counterfeit.js ──
MG.register('counterfeit', {
    title: 'Counterfeit',
    hint: 'Drag the plate onto the guides · hold it aligned to print each bill',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 420, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'grab';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const need = 3 + Math.floor(diff / 2);
        const tol = Math.max(8, 22 - diff * 3);
        const printTime = 0.55 + diff * 0.06;
        const drift = diff >= 3 ? 0.25 + diff * 0.12 : 0;
        const tx = W / 2, ty = 120, pw = 150, ph = 70;
        let printed = 0, charge = 0, done = false, last = performance.now();
        let px = 0, py = 0, dragging = false, off = { x: 0, y: 0 };

        function newPlate() { const a = Math.random() * Math.PI * 2, r = 55 + Math.random() * 55; px = tx + Math.cos(a) * r; py = ty + Math.sin(a) * r; charge = 0; }
        newPlate();
        api.setDots(need);

        function rel(e) { const b = cvs.getBoundingClientRect(); return { x: (e.clientX - b.left) * (W / b.width), y: (e.clientY - b.top) * (H / b.height) }; }
        cvs.addEventListener('mousedown', (e) => { const r = rel(e); if (Math.abs(r.x - px) < pw / 2 && Math.abs(r.y - py) < ph / 2) { dragging = true; off.x = r.x - px; off.y = r.y - py; cvs.style.cursor = 'grabbing'; } });
        cvs.addEventListener('mousemove', (e) => { if (!dragging) return; const r = rel(e); px = r.x - off.x; py = r.y - off.y; });
        cvs.addEventListener('mouseup', () => { dragging = false; cvs.style.cursor = 'grab'; });
        cvs.addEventListener('mouseleave', () => { dragging = false; });

        api.setTag('PRINTING');
        api.startTimer(Math.max(18, 32 - diff * 2), () => { if (!done) { done = true; api.stopTimer(); setTimeout(() => api.fail(), 200); } });

        function draw() {
            const now = performance.now(); const dt = Math.min(0.05, (now - last) / 1000); last = now;
            if (!done) {
                if (drift && !dragging) { px += (Math.random() - 0.5) * drift; py += (Math.random() - 0.5) * drift; }
                px = Math.max(pw / 2, Math.min(W - pw / 2, px)); py = Math.max(40 + ph / 2, Math.min(H - 30 - ph / 2, py));
                const aligned = Math.hypot(px - tx, py - ty) < tol;
                if (aligned) { charge += dt / printTime; if (charge >= 1) { printed++; api.sfx('latch'); api.setDots(need, Array.from({ length: need }, (_, i) => i < printed ? 'done' : '')); if (printed >= need) { done = true; api.stopTimer(); api.setTag('PRINTED'); setTimeout(() => api.succeed(), 300); } else newPlate(); } }
                else charge = Math.max(0, charge - dt / printTime * 1.5);
            }
            ctx.clearRect(0, 0, W, H);

            // press body
            ctx.strokeStyle = 'rgba(255,255,255,0.12)'; ctx.lineWidth = 2; ctx.strokeRect(tx - pw / 2 - 14, ty - ph / 2 - 14, pw + 28, ph + 28);
            // target guides (registration marks)
            const aligned = Math.hypot(px - tx, py - ty) < tol;
            ctx.strokeStyle = aligned ? suc : 'rgba(255,255,255,0.3)'; ctx.lineWidth = 1.5;
            ctx.setLineDash([5, 4]); ctx.strokeRect(tx - pw / 2, ty - ph / 2, pw, ph); ctx.setLineDash([]);
            ctx.beginPath(); ctx.moveTo(tx - 12, ty); ctx.lineTo(tx + 12, ty); ctx.moveTo(tx, ty - 12); ctx.lineTo(tx, ty + 12); ctx.stroke();

            // the plate (movable bill)
            ctx.save(); ctx.globalAlpha = 0.92;
            ctx.fillStyle = aligned ? 'rgba(57,217,138,0.18)' : 'rgba(0,224,184,0.12)';
            ctx.fillRect(px - pw / 2, py - ph / 2, pw, ph);
            ctx.strokeStyle = aligned ? suc : acc; ctx.lineWidth = 2; ctx.strokeRect(px - pw / 2, py - ph / 2, pw, ph);
            ctx.strokeStyle = aligned ? suc : acc; ctx.beginPath(); ctx.arc(px, py, 16, 0, Math.PI * 2); ctx.stroke();
            ctx.beginPath(); ctx.moveTo(px - 10, py); ctx.lineTo(px + 10, py); ctx.moveTo(px, py - 10); ctx.lineTo(px, py + 10); ctx.stroke();
            ctx.fillStyle = aligned ? suc : acc; ctx.font = '9px monospace'; ctx.textAlign = 'left'; ctx.fillText('$100', px - pw / 2 + 8, py - ph / 2 + 16);
            ctx.restore();

            // charge bar
            ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(40, H - 26, W - 80, 8);
            ctx.fillStyle = suc; ctx.fillRect(40, H - 26, (W - 80) * charge, 8);
            ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '10px monospace'; ctx.textAlign = 'center';
            ctx.fillText(aligned ? 'HOLD STEADY — PRINTING' : 'align the plate', W / 2, H - 32);

            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── crafting.js ──
MG.register('crafting', {
    title: 'Crafting',
    hint: 'Add ingredients in the shown order',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const seqLen = 3 + Math.floor(diff / 1.2);
        const slots = Math.min(8, 4 + diff);
        const ICONS = ['\u2697\ufe0f','\ud83e\uddea','\ud83d\udd25','\u2744\ufe0f','\u26a1','\ud83c\udf3f','\ud83d\udca7','\u2728'];
        const palette = ICONS.slice(0, slots);
        const recipe = Array.from({ length: seqLen }, () => api.randInt(0, slots - 1));

        let step = 0, ended = false, showing = true;
        api.setDots(seqLen);

        const box = document.createElement('div');
        box.style.cssText = 'display:flex;flex-direction:column;gap:16px;align-items:center;width:460px;';
        box.innerHTML = `
            <div class="label" id="lbl">RECIPE \u2014 MEMORIZE</div>
            <div id="recipe" style="display:flex;gap:10px;flex-wrap:wrap;justify-content:center;min-height:48px;"></div>
            <div id="station" style="display:grid;grid-template-columns:repeat(${Math.ceil(slots / 2)},1fr);gap:10px;"></div>`;
        api.board.appendChild(box);
        const recipeEl = box.querySelector('#recipe');
        const stationEl = box.querySelector('#station');
        const lbl = box.querySelector('#lbl');

        function renderRecipe(reveal) {
            recipeEl.innerHTML = '';
            recipe.forEach((r, i) => {
                const d = document.createElement('div');
                const show = reveal || i < step;
                d.style.cssText = `width:40px;height:40px;border-radius:8px;display:grid;place-items:center;font-size:22px;
                    border:2px solid ${i === step && !reveal ? 'var(--accent)' : 'var(--line)'};
                    ${i < step ? 'border-color:var(--success);' : ''}`;
                d.textContent = show ? palette[r] : '?';
                recipeEl.appendChild(d);
            });
        }
        palette.forEach((ic, idx) => {
            const b = document.createElement('button');
            b.className = 'btn'; b.textContent = ic; b.style.cssText = 'font-size:24px;padding:10px;min-width:0;';
            b.onclick = () => pick(idx);
            stationEl.appendChild(b);
        });
        function pick(idx) {
            if (ended || showing) return;
            if (idx === recipe[step]) {
                step++; api.sfx('step');
                api.setDots(seqLen, Array.from({ length: seqLen }, (_, i) => i < step ? 'done' : ''));
                renderRecipe(false);
                if (step >= seqLen) { finish(true); }
            } else { api.shake(); finish(false); }
        }
        function finish(ok) { if (ended) return; ended = true; api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 300); }

        renderRecipe(true);
        api.setTag('MEMORIZE');
        const showMs = Math.max(1400, 2600 - diff * 240);
        setTimeout(() => {
            if (ended) return;
            showing = false; lbl.textContent = 'CRAFT \u2014 FOLLOW THE ORDER';
            api.setTag('CRAFT');
            renderRecipe(false);
            api.startTimer(Math.max(10, 20 - diff), () => finish(false));
        }, showMs);

        return { destroy() {} };
    }
});

// ── crane.js ──
MG.register('crane', {
    title: 'Cargo Crane',
    hint: 'SPACE / click to drop · lead the swing onto the truck',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 420, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const pivot = { x: W / 2, y: 26 };
        const L = 150, maxA = 0.9, g = 0.5, floorY = H - 30;
        const swSpd = 0.03 + diff * 0.006;
        const tgW = Math.max(46, 92 - diff * 9);
        const rounds = 3;
        let phase = api.rand(0, Math.PI * 2), prevX = 0, round = 0, done = false;
        let target = newTarget(), crate = null;

        api.setDots(rounds);
        function newTarget() { return 60 + Math.random() * (W - 120); }
        function hookPos() { const a = Math.sin(phase) * maxA; return { x: pivot.x + Math.sin(a) * L, y: pivot.y + Math.cos(a) * L }; }
        prevX = hookPos().x;

        function drop() {
            if (done || crate) return;
            const h = hookPos();
            crate = { x: h.x, y: h.y, vx: (h.x - prevX), vy: 0 };
            api.sfx('whoosh');
        }
        function key(e) { if (e.code === 'Space') { e.preventDefault(); drop(); } }
        document.addEventListener('keydown', key);
        cvs.addEventListener('click', drop);

        api.setTag('HOIST');
        api.startTimer(Math.max(20, 34 - diff * 2), () => fail());
        function fail() { if (done) return; done = true; document.removeEventListener('keydown', key); api.stopTimer(); api.shake(); setTimeout(() => api.fail(), 200); }
        function win() { if (done) return; done = true; document.removeEventListener('keydown', key); api.stopTimer(); api.setTag('LOADED'); setTimeout(() => api.succeed(), 300); }
        function dotState() { return Array.from({ length: rounds }, (_, i) => i < round ? 'done' : ''); }

        function draw() {
            if (!done) { prevX = hookPos().x; phase += swSpd; }
            const h = hookPos();

            if (crate) {
                crate.vy += g; crate.x += crate.vx; crate.y += crate.vy;
                if (crate.y >= floorY - 10) {
                    if (Math.abs(crate.x - target) < tgW / 2) {
                        round++; api.setDots(rounds, dotState()); api.sfx('good');
                        if (round >= rounds) { win(); return; }
                        crate = null; target = newTarget();
                    } else { fail(); return; }
                }
            }

            ctx.clearRect(0, 0, W, H);
            ctx.strokeStyle = 'rgba(255,255,255,0.2)'; ctx.lineWidth = 4; ctx.beginPath(); ctx.moveTo(20, pivot.y); ctx.lineTo(W - 20, pivot.y); ctx.stroke();
            ctx.strokeStyle = 'rgba(255,255,255,0.5)'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(pivot.x, pivot.y); ctx.lineTo(h.x, h.y); ctx.stroke();
            if (!crate) { ctx.fillStyle = acc; ctx.shadowColor = acc; ctx.shadowBlur = 10; ctx.fillRect(h.x - 14, h.y - 12, 28, 24); ctx.shadowBlur = 0; }

            ctx.fillStyle = 'rgba(255,255,255,0.06)'; ctx.fillRect(0, floorY, W, H - floorY);
            ctx.fillStyle = 'rgba(57,217,138,0.18)'; ctx.fillRect(target - tgW / 2, floorY - 8, tgW, 8);
            ctx.strokeStyle = suc; ctx.lineWidth = 2; ctx.strokeRect(target - tgW / 2, floorY - 8, tgW, 8);

            if (crate) { ctx.fillStyle = acc; ctx.shadowColor = acc; ctx.shadowBlur = 12; ctx.fillRect(crate.x - 14, crate.y - 12, 28, 24); ctx.shadowBlur = 0; }

            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); } };
    }
});

// ── daemonrun.js ──
MG.register('daemonrun', {
    title: 'Daemon Run',
    hint: 'WASD / arrows · grab all data · dodge the trace',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const COLS = 11, ROWS = 9, S = 30;
        const W = COLS * S, H = ROWS * S;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const maze = [];
        for (let r = 0; r < ROWS; r++) {
            maze[r] = [];
            for (let c = 0; c < COLS; c++) {
                let wall = (r === 0 || c === 0 || r === ROWS - 1 || c === COLS - 1);
                if (!wall && r % 2 === 0 && c % 2 === 0) wall = true;
                maze[r][c] = wall ? 1 : 0;
            }
        }
        const open = [];
        for (let r = 1; r < ROWS - 1; r++) for (let c = 1; c < COLS - 1; c++)
            if (maze[r][c] === 0) open.push({ r, c });

        function popOpen() { return open.splice(api.randInt(0, open.length - 1), 1)[0]; }

        const player = popOpen();
        const fragCount = 3 + diff;
        const frags = [];
        for (let i = 0; i < fragCount && open.length; i++) frags.push(popOpen());
        const trace = open.length ? popOpen() : { r: 1, c: 1 };

        let pPix = { x: player.c * S, y: player.r * S };
        let tPix = { x: trace.c * S, y: trace.r * S };
        const traceSpeed = 0.9 + diff * 0.35;
        let moveDir = null, caught = false, won = false;

        const keymap = {
            ArrowUp: [0, -1], KeyW: [0, -1],
            ArrowDown: [0, 1], KeyS: [0, 1],
            ArrowLeft: [-1, 0], KeyA: [-1, 0],
            ArrowRight: [1, 0], KeyD: [1, 0]
        };
        function key(e) {
            const m = keymap[e.code]; if (!m) return; e.preventDefault();
            const nc = player.c + m[0], nr = player.r + m[1];
            if (maze[nr] && maze[nr][nc] === 0) { player.c = nc; player.r = nr; }
        }
        document.addEventListener('keydown', key);

        api.setDots(fragCount);
        api.startTimer(Math.max(14, 30 - diff * 2), () => finish(false));

        function finish(ok) {
            if (caught || won) return;
            won = ok; caught = !ok;
            document.removeEventListener('keydown', key);
            api.stopTimer();
            setTimeout(() => ok ? api.succeed() : api.fail(), 250);
        }

        let traceTick = 0;
        function moveTrace() {
            const tr = Math.round(tPix.y / S), tc = Math.round(tPix.x / S);
            const opts = [[0, -1], [0, 1], [-1, 0], [1, 0]].filter(([dc, dr]) =>
                maze[tr + dr] && maze[tr + dr][tc + dc] === 0);
            if (!opts.length) return;
            opts.sort((a, b) => {
                const da = Math.hypot((tc + a[0]) - player.c, (tr + a[1]) - player.r);
                const db = Math.hypot((tc + b[0]) - player.c, (tr + b[1]) - player.r);
                return da - db;
            });
            const pick = Math.random() < 0.78 ? opts[0] : opts[api.randInt(0, opts.length - 1)];
            trace.c = tc + pick[0]; trace.r = tr + pick[1];
        }

        function draw() {
            ctx.clearRect(0, 0, W, H);
            for (let r = 0; r < ROWS; r++) for (let c = 0; c < COLS; c++) {
                if (maze[r][c] === 1) {
                    ctx.fillStyle = 'rgba(255,255,255,0.05)';
                    ctx.fillRect(c * S, r * S, S, S);
                    ctx.strokeStyle = 'rgba(255,255,255,0.08)';
                    ctx.strokeRect(c * S, r * S, S, S);
                }
            }
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff3b5c').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();

            frags.forEach((f) => {
                if (f.got) return;
                ctx.fillStyle = suc; ctx.shadowColor = suc; ctx.shadowBlur = 8;
                ctx.beginPath(); ctx.arc(f.c * S + S / 2, f.r * S + S / 2, 5, 0, Math.PI * 2); ctx.fill();
                ctx.shadowBlur = 0;
            });

            pPix.x += (player.c * S - pPix.x) * 0.35;
            pPix.y += (player.r * S - pPix.y) * 0.35;
            ctx.fillStyle = acc; ctx.shadowColor = acc; ctx.shadowBlur = 10;
            ctx.beginPath(); ctx.arc(pPix.x + S / 2, pPix.y + S / 2, S / 2 - 5, 0, Math.PI * 2); ctx.fill();
            ctx.shadowBlur = 0;

            traceTick += traceSpeed;
            if (traceTick >= 10) { traceTick = 0; moveTrace(); }
            tPix.x += (trace.c * S - tPix.x) * 0.18;
            tPix.y += (trace.r * S - tPix.y) * 0.18;
            ctx.fillStyle = dng; ctx.shadowColor = dng; ctx.shadowBlur = 12;
            ctx.beginPath(); ctx.arc(tPix.x + S / 2, tPix.y + S / 2, S / 2 - 4, 0, Math.PI * 2); ctx.fill();
            ctx.shadowBlur = 0;

            let got = 0;
            frags.forEach((f) => {
                if (!f.got && f.r === player.r && f.c === player.c) f.got = true;
                if (f.got) got++;
            });
            api.setDots(fragCount, frags.map((f) => f.got ? 'done' : ''));

            if (Math.hypot(tPix.x - pPix.x, tPix.y - pPix.y) < S * 0.6) { finish(false); return; }
            if (got >= fragCount) { finish(true); return; }

            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); } };
    }
});

// ── dataheist.js ──
MG.register('dataheist', {
    title: 'Data Heist',
    hint: 'Catch the clean data · dodge the corrupt (red) packets',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 420, H = 300;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'none';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const need = 8 + diff * 2;
        const maxMiss = Math.max(2, 5 - diff);
        const fallSpeed = 1.8 + diff * 0.6;
        const spawnGap = Math.max(28, 60 - diff * 6);
        const corruptChance = 0.22 + diff * 0.04;

        let packets = [], grabbed = 0, miss = 0, frame = 0, ended = false;
        let paddle = W / 2, hasMouse = false;
        const padW = Math.max(50, 90 - diff * 8), padY = H - 28;
        api.setDots(maxMiss);

        function rel(e) {
            const b = cvs.getBoundingClientRect();
            return (e.clientX - b.left) * (cvs.width / b.width);
        }
        cvs.addEventListener('mousemove', (e) => { paddle = rel(e); hasMouse = true; });

        api.setTag('0/' + need);
        api.startTimer(Math.max(16, 30 - diff * 2), () => finish(grabbed >= need));
        function registerMiss() { miss++; api.setDots(maxMiss, Array.from({ length: maxMiss }, (_, i) => i < miss ? 'fail' : '')); if (miss >= maxMiss) finish(false); }
        function finish(ok) { if (ended) return; ended = true; api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 250); }

        function draw() {
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff3b5c').trim();
            frame++;
            if (!ended && frame % spawnGap === 0) {
                packets.push({ x: api.rand(20, W - 20), y: -14, corrupt: Math.random() < corruptChance, gone: false });
            }
            ctx.clearRect(0, 0, W, H);
            ctx.strokeStyle = 'rgba(255,255,255,0.06)';
            for (let i = 0; i < W; i += 20) { ctx.beginPath(); ctx.moveTo(i, 0); ctx.lineTo(i, H); ctx.globalAlpha = 0.3; ctx.stroke(); ctx.globalAlpha = 1; }

            packets.forEach((p) => {
                if (p.gone) return;
                if (!ended) p.y += fallSpeed;
                const caught = p.y > padY - 8 && p.y < padY + 8 && Math.abs(p.x - paddle) < padW / 2;
                if (caught) {
                    p.gone = true;
                    if (p.corrupt) { api.shake(); registerMiss(); }
                    else { grabbed++; api.sfx('beep'); api.setTag(grabbed + '/' + need); if (grabbed >= need) finish(true); }
                    return;
                }
                if (p.y > H + 14) { p.gone = true; if (!p.corrupt) registerMiss(); return; }
                ctx.fillStyle = p.corrupt ? dng : suc; ctx.shadowColor = ctx.fillStyle; ctx.shadowBlur = 8;
                ctx.fillRect(p.x - 7, p.y - 7, 14, 14); ctx.shadowBlur = 0;
                ctx.fillStyle = '#0a0e14'; ctx.font = '9px monospace'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
                ctx.fillText(p.corrupt ? '✕' : '1', p.x, p.y);
            });
            packets = packets.filter((p) => !p.gone);

            if (hasMouse) {
                paddle = Math.max(padW / 2, Math.min(W - padW / 2, paddle));
                ctx.fillStyle = acc; ctx.shadowColor = acc; ctx.shadowBlur = 10;
                ctx.fillRect(paddle - padW / 2, padY, padW, 8); ctx.shadowBlur = 0;
            } else {
                ctx.fillStyle = 'rgba(255,255,255,0.4)'; ctx.font = '12px monospace'; ctx.textAlign = 'center';
                ctx.fillText('move mouse to catch packets', W / 2, padY - 10);
            }
            if (!ended) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── deadcalm.js ──
MG.register('deadcalm', {
    title: 'Dead Calm',
    hint: 'Hold SPACE to steady · CLICK to fire',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const need = api.cfg.shots || 3;
        const W = 420, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const targetR = Math.max(22, 50 - diff * 6);
        const drift = 0.9 + diff * 0.45;
        let tx = W / 2, ty = H / 2;
        let cx = W / 2, cy = H / 2;
        let phase = Math.random() * 100;
        let holding = false, breath = 1, shots = 0;
        let tvx = api.rand(-0.4, 0.4), tvy = api.rand(-0.4, 0.4);

        api.setDots(need);
        api.startTimer(Math.max(11, 24 - diff * 1.8), () => { unbind(); api.fail(); });

        function down(e) { if (e.code === 'Space') { e.preventDefault(); holding = true; } }
        function up(e)   { if (e.code === 'Space') { e.preventDefault(); holding = false; } }
        function fire() {
            const inside = Math.hypot(cx - tx, cy - ty) < targetR * 0.6;
            if (inside) {
                shots++;
                const st = []; for (let i = 0; i < need; i++) st[i] = i < shots ? 'done' : '';
                api.setDots(need, st);
                if (shots >= need) { api.stopTimer(); unbind(); setTimeout(() => api.succeed(), 250); return; }
                tx = api.rand(80, W - 80); ty = api.rand(80, H - 80);
            } else {
                api.shake(); api.stopTimer(); unbind();
                setTimeout(() => api.fail(), 200);
            }
        }
        document.addEventListener('keydown', down);
        document.addEventListener('keyup', up);
        cvs.addEventListener('click', fire);
        function unbind() {
            document.removeEventListener('keydown', down);
            document.removeEventListener('keyup', up);
        }

        function draw() {
            phase += 0.05;
            if (holding) breath = Math.max(0, breath - 0.012);
            else breath = Math.min(1, breath + 0.006);

            const steady = holding && breath > 0;
            const amp = steady ? drift * 1.2 : drift * (breath <= 0 ? 9 : 5.5);
            const wob = amp;
            cx = tx + Math.sin(phase * 1.7) * wob + Math.sin(phase * 0.6) * wob * 0.6;
            cy = ty + Math.cos(phase * 1.3) * wob + Math.cos(phase * 0.9) * wob * 0.6;

            tx += tvx; ty += tvy;
            if (tx < 70 || tx > W - 70) tvx *= -1;
            if (ty < 70 || ty > H - 70) tvy *= -1;

            ctx.clearRect(0, 0, W, H);
            ctx.strokeStyle = 'rgba(255,255,255,0.05)'; ctx.lineWidth = 1;
            for (let i = 0; i < W; i += 30) { ctx.beginPath(); ctx.moveTo(i, 0); ctx.lineTo(i, H); ctx.stroke(); }
            for (let j = 0; j < H; j += 30) { ctx.beginPath(); ctx.moveTo(0, j); ctx.lineTo(W, j); ctx.stroke(); }

            ctx.strokeStyle = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff3b5c').trim();
            ctx.lineWidth = 2;
            ctx.beginPath(); ctx.arc(tx, ty, targetR, 0, Math.PI * 2); ctx.stroke();
            ctx.beginPath(); ctx.arc(tx, ty, targetR * 0.6, 0, Math.PI * 2);
            ctx.setLineDash([4, 4]); ctx.stroke(); ctx.setLineDash([]);

            const acc = getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8';
            ctx.strokeStyle = acc; ctx.lineWidth = 2;
            ctx.shadowColor = acc; ctx.shadowBlur = steady ? 12 : 0;
            ctx.beginPath(); ctx.arc(cx, cy, 10, 0, Math.PI * 2); ctx.stroke();
            ctx.beginPath();
            ctx.moveTo(cx - 18, cy); ctx.lineTo(cx - 4, cy);
            ctx.moveTo(cx + 4, cy); ctx.lineTo(cx + 18, cy);
            ctx.moveTo(cx, cy - 18); ctx.lineTo(cx, cy - 4);
            ctx.moveTo(cx, cy + 4); ctx.lineTo(cx, cy + 18);
            ctx.stroke(); ctx.shadowBlur = 0;

            ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(20, H - 16, W - 40, 6);
            ctx.fillStyle = breath > 0.25 ? acc : '#ff3b5c';
            ctx.fillRect(20, H - 16, (W - 40) * breath, 6);

            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); unbind(); } };
    }
});

// ── diving.js ──
MG.register('diving', {
    title: 'Salvage Dive',
    hint: 'Move to grab the loot · surface to breathe before air runs out',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 420, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'crosshair';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const need = 4 + diff;
        const surfaceY = 42;
        const drain = 0.05 + diff * 0.015, refill = 0.55;
        let air = 1, collected = 0, done = false, last = performance.now();
        const diver = { x: W / 2, y: surfaceY + 24, r: 9 };
        let mx = diver.x, my = diver.y, has = false;

        const items = [];
        for (let i = 0; i < need; i++) items.push({ x: 36 + Math.random() * (W - 72), y: surfaceY + 78 + Math.random() * (H - surfaceY - 120), got: false });

        cvs.addEventListener('mousemove', (e) => { const b = cvs.getBoundingClientRect(); mx = (e.clientX - b.left) * (W / b.width); my = (e.clientY - b.top) * (H / b.height); has = true; });

        api.setTag('DIVE');
        api.startTimer(Math.max(28, 46 - diff * 2), () => { if (!done) finish(collected >= need); });
        function finish(ok) { if (done) return; done = true; api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 250); }

        function draw() {
            const now = performance.now(); const dt = Math.min(0.05, (now - last) / 1000); last = now;
            if (!done) {
                if (has) { diver.x += (mx - diver.x) * 0.18; diver.y += (my - diver.y) * 0.18; }
                diver.x = Math.max(diver.r, Math.min(W - diver.r, diver.x));
                diver.y = Math.max(surfaceY - 6, Math.min(H - diver.r, diver.y));
                const atSurface = diver.y <= surfaceY + 16;
                air = Math.max(0, Math.min(1, air + (atSurface ? refill : -drain * (0.7 + diver.y / H)) * dt));
                if (air <= 0) { finish(false); return; }
                items.forEach(it => { if (!it.got && Math.hypot(diver.x - it.x, diver.y - it.y) < diver.r + 9) { it.got = true; collected++; api.sfx('beep'); api.setTag(collected + '/' + need); if (collected >= need) finish(true); } });
            }
            ctx.clearRect(0, 0, W, H);

            // water
            const grd = ctx.createLinearGradient(0, surfaceY, 0, H);
            grd.addColorStop(0, 'rgba(0,150,180,0.10)'); grd.addColorStop(1, 'rgba(0,40,80,0.22)');
            ctx.fillStyle = grd; ctx.fillRect(0, surfaceY, W, H - surfaceY);
            ctx.strokeStyle = 'rgba(0,224,184,0.4)'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(0, surfaceY); ctx.lineTo(W, surfaceY); ctx.stroke();
            ctx.fillStyle = 'rgba(255,255,255,0.3)'; ctx.font = '9px monospace'; ctx.textAlign = 'left'; ctx.fillText('SURFACE', 8, surfaceY - 4);

            // loot
            items.forEach(it => { if (it.got) return; ctx.fillStyle = '#ffd23f'; ctx.shadowColor = '#ffd23f'; ctx.shadowBlur = 10; ctx.fillRect(it.x - 7, it.y - 7, 14, 14); ctx.shadowBlur = 0; ctx.fillStyle = 'rgba(0,0,0,0.3)'; ctx.fillRect(it.x - 7, it.y - 1, 14, 3); });

            // diver
            ctx.fillStyle = acc; ctx.shadowColor = acc; ctx.shadowBlur = 12; ctx.beginPath(); ctx.arc(diver.x, diver.y, diver.r, 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0;

            // air bar
            ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(12, H - 18, W - 24, 8);
            ctx.fillStyle = air < 0.25 ? dng : suc; ctx.fillRect(12, H - 18, (W - 24) * air, 8);
            ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '9px monospace'; ctx.textAlign = 'left'; ctx.fillText('AIR  ·  LOOT ' + collected + '/' + need, 12, H - 22);

            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── drilling.js ──
MG.register('drilling', {
    title: 'Drilling',
    hint: 'Hold to drill · keep pressure in the green, don\u2019t overheat',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 360, H = 280;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const bandLow = 45, bandHigh = 72;
        const rise = 1.4 + diff * 0.5;
        const fall = 1.1 + diff * 0.25;
        const wander = diff * 0.5;
        let pressure = 20, depth = 0, heat = 0, holding = false, ended = false;

        function down(e) { if (e.code === 'Space') { e.preventDefault(); holding = true; } }
        function up(e) { if (e.code === 'Space') { e.preventDefault(); holding = false; } }
        document.addEventListener('keydown', down);
        document.addEventListener('keyup', up);
        cvs.addEventListener('mousedown', () => holding = true);
        window.addEventListener('mouseup', mUp);
        function mUp() { holding = false; }

        api.setTag('DRILLING');
        api.startTimer(Math.max(13, 24 - diff * 1.6), () => finish(false));
        function finish(ok) {
            if (ended) return; ended = true;
            document.removeEventListener('keydown', down);
            document.removeEventListener('keyup', up);
            window.removeEventListener('mouseup', mUp);
            api.stopTimer();
            setTimeout(() => ok ? api.succeed() : api.fail(), 250);
        }

        function draw() {
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff3b5c').trim();
            if (!ended) {
                pressure += (holding ? rise : -fall) + (Math.random() - 0.5) * wander;
                pressure = Math.max(0, Math.min(100, pressure));
                const inBand = pressure >= bandLow && pressure <= bandHigh;
                if (inBand) { depth += 0.7; api.sfx('tick'); heat = Math.max(0, heat - 0.4); }
                else { heat += pressure > bandHigh ? 1.4 : 0.2; }
                api.setTag(inBand ? 'DRILLING' : (pressure > bandHigh ? 'TOO HARD' : 'TOO SOFT'));
                if (heat >= 100) { finish(false); return; }
                if (depth >= 100) { finish(true); return; }
            }
            ctx.clearRect(0, 0, W, H);
            const gx = 50, gw = 50, gy = 30, gh = H - 90;
            ctx.fillStyle = 'rgba(255,255,255,0.06)'; ctx.fillRect(gx, gy, gw, gh);
            const by = gy + gh * (1 - bandHigh / 100), bh = gh * (bandHigh - bandLow) / 100;
            ctx.fillStyle = 'rgba(57,217,138,0.18)'; ctx.strokeStyle = suc; ctx.lineWidth = 2;
            ctx.fillRect(gx, by, gw, bh); ctx.strokeRect(gx, by, gw, bh);
            const py = gy + gh * (1 - pressure / 100);
            ctx.fillStyle = '#fff'; ctx.shadowColor = acc; ctx.shadowBlur = 10;
            ctx.fillRect(gx - 6, py - 2, gw + 12, 4); ctx.shadowBlur = 0;
            ctx.fillStyle = acc; ctx.font = '10px monospace'; ctx.textAlign = 'center';
            ctx.fillText('PRESSURE', gx + gw / 2, gy + gh + 16);

            const dx = 160, dw = 36;
            ctx.fillStyle = 'rgba(255,255,255,0.08)'; ctx.fillRect(dx, gy, dw, gh);
            ctx.fillStyle = suc; const dfh = gh * depth / 100;
            ctx.fillRect(dx, gy + gh - dfh, dw, dfh);
            ctx.fillStyle = acc; ctx.fillText('DEPTH', dx + dw / 2, gy + gh + 16);

            const hx = 250, hw = 36;
            ctx.fillStyle = 'rgba(255,255,255,0.08)'; ctx.fillRect(hx, gy, hw, gh);
            ctx.fillStyle = heat > 60 ? dng : 'rgba(255,140,0,0.8)'; const hfh = gh * heat / 100;
            ctx.fillRect(hx, gy + gh - hfh, hw, hfh);
            ctx.fillStyle = acc; ctx.fillText('HEAT', hx + hw / 2, gy + gh + 16);

            ctx.fillStyle = 'rgba(255,255,255,0.4)'; ctx.font = '12px monospace';
            ctx.fillText('hold SPACE to drill', W / 2, H - 14);
            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', down); document.removeEventListener('keyup', up); window.removeEventListener('mouseup', mUp); } };
    }
});

// ── eaglevision.js ──
MG.register('eaglevision', {
    title: 'Eagle Vision',
    hint: 'Memorize the mark · then click every match',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 480, H = 300;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'crosshair';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const SHAPES = ['triangle', 'square', 'diamond', 'hex'];
        const COLORS = ['#ff4d6d', '#ffd23f', '#00e0b8', '#5b8cff', '#c06bff'];
        const sig = { shape: SHAPES[api.randInt(0, SHAPES.length - 1)], color: COLORS[api.randInt(0, COLORS.length - 1)] };

        const figCount = 8 + diff * 3;
        const targetCount = 2 + Math.floor(diff / 1.5);
        const figs = [];
        for (let i = 0; i < targetCount; i++) figs.push({ ...spot(), shape: sig.shape, color: sig.color, target: true, found: false });
        for (let i = 0; i < figCount - targetCount; i++) {
            let sh = sig.shape, cl = sig.color;
            if (Math.random() < 0.5) sh = SHAPES[(SHAPES.indexOf(sig.shape) + api.randInt(1, 3)) % SHAPES.length];
            else cl = COLORS[(COLORS.indexOf(sig.color) + api.randInt(1, 4)) % COLORS.length];
            figs.push({ ...spot(), shape: sh, color: cl, target: false, found: false });
        }
        function spot() {
            return { x: api.rand(40, W - 40), y: api.rand(50, H - 40) };
        }

        let phase = 'show', found = 0, mouse = { x: -99, y: -99 }, ended = false;
        api.setDots(targetCount);
        api.setTag('SIGNATURE');

        setTimeout(() => { phase = 'hunt'; api.setTag('HUNT'); api.startTimer(Math.max(8, 16 - diff), () => finish()); }, Math.max(1100, 2000 - diff * 180));

        function rel(e) {
            const b = cvs.getBoundingClientRect();
            return { x: (e.clientX - b.left) * (cvs.width / b.width),
                     y: (e.clientY - b.top) * (cvs.height / b.height) };
        }
        cvs.addEventListener('mousemove', (e) => { mouse = rel(e); });
        cvs.addEventListener('click', (e) => {
            if (phase !== 'hunt' || ended) return;
            const p = rel(e);
            const f = figs.find((g) => !g.found && Math.hypot(g.x - p.x, g.y - p.y) < 18);
            if (!f) return;
            if (f.target) {
                f.found = true; found++;
                api.setDots(targetCount, Array.from({ length: targetCount }, (_, i) => i < found ? 'done' : ''));
                if (found >= targetCount) finish(true);
            } else {
                api.shake(); finish(false);
            }
        });
        function finish(ok) {
            if (ended) return; ended = true;
            api.stopTimer();
            const pass = ok === true || found >= targetCount;
            setTimeout(() => pass ? api.succeed() : api.fail(), 300);
        }

        function shape(x, y, type, color, lit, size) {
            ctx.fillStyle = color;
            ctx.strokeStyle = color;
            ctx.shadowColor = color; ctx.shadowBlur = lit ? 16 : 0;
            ctx.globalAlpha = lit ? 1 : 0.5;
            ctx.beginPath();
            const s = size || 12;
            if (type === 'triangle') { ctx.moveTo(x, y - s); ctx.lineTo(x + s, y + s); ctx.lineTo(x - s, y + s); }
            else if (type === 'square') { ctx.rect(x - s, y - s, s * 2, s * 2); }
            else if (type === 'diamond') { ctx.moveTo(x, y - s); ctx.lineTo(x + s, y); ctx.lineTo(x, y + s); ctx.lineTo(x - s, y); }
            else { for (let i = 0; i < 6; i++) { const a = i / 6 * Math.PI * 2; const px = x + Math.cos(a) * s, py = y + Math.sin(a) * s; i ? ctx.lineTo(px, py) : ctx.moveTo(px, py); } }
            ctx.closePath(); ctx.fill();
            ctx.globalAlpha = 1; ctx.shadowBlur = 0;
        }

        function draw() {
            ctx.clearRect(0, 0, W, H);
            if (phase === 'show') {
                ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '13px monospace'; ctx.textAlign = 'center';
                ctx.fillText('TARGET SIGNATURE', W / 2, H / 2 - 50);
                shape(W / 2, H / 2 + 4, sig.shape, sig.color, true, 22);
            } else {
                const grad = ctx.createRadialGradient(mouse.x, mouse.y, 10, mouse.x, mouse.y, 70);
                grad.addColorStop(0, 'rgba(255,255,255,0.10)'); grad.addColorStop(1, 'transparent');
                ctx.fillStyle = grad; ctx.fillRect(0, 0, W, H);

                figs.forEach((f) => {
                    if (f.found) { shape(f.x, f.y, f.shape, '#39d98a', true); return; }
                    const near = Math.hypot(f.x - mouse.x, f.y - mouse.y) < 70;
                    shape(f.x, f.y, f.shape, f.color, near);
                });
            }
            if (!ended) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── fishing.js ──
MG.register('fishing', {
    title: 'Fishing',
    hint: 'Wait for the bite · then keep the fish in the zone',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 360, H = 320;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const reelGoal = 100;
        const zoneH = Math.max(50, 110 - diff * 12);
        const fishSpeed = 0.8 + diff * 0.6;
        const drain = 0.35 + diff * 0.12;

        let phase = 'wait', biteAt = 0, ended = false;
        let zoneY = H / 2, holding = false;
        let fishY = H / 2, fishVel = 0, fishTimer = 0;
        let reel = 25;

        const delay = api.rand(1200, 3200);
        const waitTO = setTimeout(() => { if (!ended) { phase = 'reel'; biteAt = performance.now(); api.setTag('REEL!'); } }, delay);

        function down(e) { if (e.code === 'Space') { e.preventDefault(); holding = true; } }
        function up(e) { if (e.code === 'Space') { e.preventDefault(); holding = false; } }
        document.addEventListener('keydown', down);
        document.addEventListener('keyup', up);
        cvs.addEventListener('mousedown', () => holding = true);
        window.addEventListener('mouseup', mUp);
        function mUp() { holding = false; }

        api.setTag('WAITING');
        api.startTimer(Math.max(14, 26 - diff * 2), () => finish(false));

        function finish(ok) {
            if (ended) return; ended = true;
            clearTimeout(waitTO);
            document.removeEventListener('keydown', down);
            document.removeEventListener('keyup', up);
            window.removeEventListener('mouseup', mUp);
            api.stopTimer();
            setTimeout(() => ok ? api.succeed() : api.fail(), 250);
        }

        function draw() {
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            ctx.clearRect(0, 0, W, H);

            ctx.fillStyle = 'rgba(91,140,255,0.06)';
            ctx.fillRect(40, 20, 80, H - 40);
            ctx.strokeStyle = 'rgba(255,255,255,0.1)';
            ctx.strokeRect(40, 20, 80, H - 40);

            if (phase === 'wait') {
                ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '14px monospace'; ctx.textAlign = 'center';
                ctx.fillText('waiting for a bite…', W / 2, H / 2);
                const bob = Math.sin(performance.now() / 300) * 4;
                ctx.fillStyle = acc; ctx.beginPath(); ctx.arc(80, H / 2 + bob, 7, 0, Math.PI * 2); ctx.fill();
            } else if (phase === 'reel') {
                if (!ended) {
                    zoneY += (holding ? -2.4 : 2.0);
                    zoneY = Math.max(20 + zoneH / 2, Math.min(H - 20 - zoneH / 2, zoneY));
                    fishTimer -= 1;
                    if (fishTimer <= 0) { fishVel = api.rand(-fishSpeed, fishSpeed); fishTimer = api.randInt(20, 50); }
                    fishY += fishVel;
                    fishY = Math.max(30, Math.min(H - 30, fishY));
                    const inside = fishY > zoneY - zoneH / 2 && fishY < zoneY + zoneH / 2;
                    reel += inside ? 0.8 : -drain;
                    reel = Math.max(0, Math.min(reelGoal, reel));
                    api.setTag(inside ? 'REELING' : 'SLIPPING');
                    if (reel >= reelGoal) { finish(true); return; }
                    if (reel <= 0 && performance.now() - biteAt > 1500) { finish(false); return; }
                }
                const inside = fishY > zoneY - zoneH / 2 && fishY < zoneY + zoneH / 2;
                ctx.fillStyle = inside ? 'rgba(57,217,138,0.2)' : 'rgba(0,224,184,0.12)';
                ctx.strokeStyle = inside ? suc : acc; ctx.lineWidth = 2;
                ctx.fillRect(45, zoneY - zoneH / 2, 70, zoneH);
                ctx.strokeRect(45, zoneY - zoneH / 2, 70, zoneH);
                ctx.fillStyle = '#fff'; ctx.shadowColor = acc; ctx.shadowBlur = 10;
                ctx.beginPath(); ctx.arc(80, fishY, 9, 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0;
                ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(W - 40, 20, 14, H - 40);
                ctx.fillStyle = suc;
                const rh = (H - 40) * (reel / reelGoal);
                ctx.fillRect(W - 40, 20 + (H - 40 - rh), 14, rh);
            }
            if (!ended) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); clearTimeout(waitTO); document.removeEventListener('keydown', down); document.removeEventListener('keyup', up); window.removeEventListener('mouseup', mUp); } };
    }
});

// ── flatline.js ──
MG.register('flatline', {
    title: 'Flatline',
    hint: 'SPACE inside the green zone',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const need = api.cfg.rounds || 3;
        const W = 480, H = 240;

        const wrap = document.createElement('div');
        wrap.style.cssText = `width:${W}px;`;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        wrap.appendChild(cvs);
        api.board.appendChild(wrap);
        const ctx = cvs.getContext('2d');

        let done = 0, fails = 0, pos = 0, dir = 1;
        const speed = 1.7 + diff * 0.95;
        const zoneW = Math.max(38, 120 - diff * 14);
        let zoneX = rnd();
        api.setDots(need);

        function rnd() { return 60 + Math.random() * (W - 120 - zoneW); }

        function attempt() {
            const center = zoneX + zoneW / 2;
            const hit = pos >= zoneX && pos <= zoneX + zoneW;
            if (hit) {
                done++;
                api.setDots(need, fillStates());
                if (done >= need) { api.stopTimer(); cleanupKeys(); setTimeout(() => api.succeed(), 250); return; }
                zoneX = rnd();
            } else {
                fails++;
                api.shake();
                api.setDots(need, fillStates(true));
                if (fails >= 2) { api.stopTimer(); cleanupKeys(); setTimeout(() => api.fail(), 250); return; }
                zoneX = rnd();
            }
        }
        function fillStates(markFail) {
            const s = [];
            for (let i = 0; i < need; i++) s[i] = i < done ? 'done' : '';
            return s;
        }

        function key(e) {
            if (e.code === 'Space') { e.preventDefault(); attempt(); }
        }
        document.addEventListener('keydown', key);
        function cleanupKeys() { document.removeEventListener('keydown', key); }

        api.startTimer(Math.max(8, 20 - diff * 1.6), () => { cleanupKeys(); api.fail(); });

        function ecg(x) {
            const baseline = H * 0.6;
            const t = (x / W) * Math.PI * 8;
            let y = Math.sin(t) * 3;
            const beat = (x % 120);
            if (beat > 40 && beat < 60) y -= Math.sin((beat - 40) / 20 * Math.PI) * 55;
            return baseline + y;
        }

        function draw() {
            ctx.clearRect(0, 0, W, H);
            ctx.strokeStyle = 'rgba(57,217,138,0.5)'; ctx.lineWidth = 2;
            ctx.beginPath();
            for (let x = 0; x <= W; x += 2) { const y = ecg(x); x ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
            ctx.stroke();

            ctx.fillStyle = 'rgba(57,217,138,0.16)';
            ctx.strokeStyle = '#39d98a'; ctx.lineWidth = 2;
            ctx.fillRect(zoneX, 30, zoneW, H - 60);
            ctx.strokeRect(zoneX, 30, zoneW, H - 60);

            pos += dir * speed;
            if (pos > W - 40) { pos = W - 40; dir = -1; }
            if (pos < 40) { pos = 40; dir = 1; }
            ctx.strokeStyle = '#fff'; ctx.lineWidth = 3;
            ctx.shadowColor = '#fff'; ctx.shadowBlur = 12;
            ctx.beginPath(); ctx.moveTo(pos, 24); ctx.lineTo(pos, H - 24); ctx.stroke();
            ctx.shadowBlur = 0;

            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); cleanupKeys(); } };
    }
});

// ── gaslight.js ──
MG.register('gaslight', {
    title: 'Gaslight',
    hint: 'Memorize the scene · then answer',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const rounds = 3;
        const itemCount = 3 + diff;
        const flashMs = Math.max(700, 1900 - diff * 280);

        const ICONS = ['🔑','💊','📁','💵','🔫','📱','💎','🧪','📷','🎫','🧨','🗝️'];
        let round = 0, correct = 0;
        api.setDots(rounds);

        const box = document.createElement('div');
        box.style.cssText = 'width:480px;min-height:300px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:20px;';
        api.board.appendChild(box);

        api.startTimer(flashMs / 1000 * rounds + rounds * 6, () => finish());

        function scene() {
            if (round >= rounds) { finish(); return; }
            api.setTag('OBSERVE ' + (round + 1) + '/' + rounds);
            const items = [];
            const used = new Set();
            while (items.length < itemCount) {
                const ic = ICONS[api.randInt(0, ICONS.length - 1)];
                if (!used.has(ic)) { used.add(ic); items.push(ic); }
            }
            box.innerHTML = `<div class="label">MEMORIZE</div>
                <div style="display:grid;grid-template-columns:repeat(${Math.ceil(Math.sqrt(itemCount))},1fr);
                     gap:18px;font-size:46px;">
                     ${items.map(i => `<span>${i}</span>`).join('')}
                </div>`;
            setTimeout(() => question(items), flashMs);
        }

        function question(items) {
            const qType = api.randInt(0, Math.min(2, diff - 1 < 0 ? 0 : diff - 1));
            let prompt, answer, options;

            if (qType === 0) {
                const present = Math.random() < 0.5;
                const pick = present ? items[api.randInt(0, items.length - 1)]
                                     : pickAbsent(items);
                prompt = `Was this item in the scene?  ${pick}`;
                answer = present ? 'YES' : 'NO';
                options = ['YES', 'NO'];
            } else if (qType === 1) {
                prompt = 'How many items did you see?';
                answer = String(items.length);
                const set = new Set([items.length]);
                while (set.size < 4) set.add(api.randInt(Math.max(1, items.length - 2), items.length + 2));
                options = [...set].sort(() => Math.random() - 0.5).map(String);
            } else {
                const real = items[api.randInt(0, items.length - 1)];
                prompt = 'Which item was present?';
                answer = real;
                const set = new Set([real]);
                while (set.size < 4) set.add(ICONS[api.randInt(0, ICONS.length - 1)]);
                options = [...set].sort(() => Math.random() - 0.5);
            }
            api.setTag('RECALL');

            box.innerHTML = `<div class="label">RECALL</div>
                <div style="font-family:var(--display);font-size:18px;">${prompt}</div>
                <div id="opts" style="display:flex;gap:12px;flex-wrap:wrap;justify-content:center;"></div>`;
            const opts = box.querySelector('#opts');
            options.forEach(o => {
                const b = document.createElement('button');
                b.className = 'btn';
                b.style.fontSize = o.length <= 2 ? '24px' : '14px';
                b.textContent = o;
                b.onclick = () => answerPicked(o === answer);
                opts.appendChild(b);
            });
        }

        function pickAbsent(items) {
            let ic;
            do { ic = ICONS[api.randInt(0, ICONS.length - 1)]; } while (items.includes(ic));
            return ic;
        }

        function answerPicked(ok) {
            if (ok) correct++; else api.shake();
            const st = [];
            for (let i = 0; i < rounds; i++) {
                if (i < round) st[i] = (i < correct) ? 'done' : 'fail';
                else st[i] = '';
            }
            round++;
            const st2 = [];
            for (let i = 0; i < rounds; i++) {
                if (i < round) st2[i] = (i < correct) ? 'done' : 'fail';
                else st2[i] = (i === round) ? 'active' : '';
            }
            api.setDots(rounds, st2);
            setTimeout(scene, 400);
        }

        function finish() {
            const pass = correct >= Math.ceil(rounds / 2 + (diff >= 4 ? 0.5 : 0));
            api.stopTimer();
            setTimeout(() => pass ? api.succeed() : api.fail(), 200);
        }

        scene();
        return { destroy() {} };
    }
});

// ── getaway.js ──
MG.register('getaway', {
    title: 'Getaway',
    hint: 'A / D (or ← →) to switch lanes · dodge traffic until you’re clear',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const lanes = 3;
        const W = 300, H = 330;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const laneX = (i) => (W / lanes) * (i + 0.5);
        let targetLane = 1, carX = laneX(1);
        const carW = 36, carH = 58, carY = H - 70;
        let done = false, dash = 0, spawnT = 0;
        const speed = 3 + diff * 0.7;
        const spawnEvery = Math.max(22, 60 - diff * 7);
        const traffic = [];

        function key(e) {
            if (done) return;
            if (e.code === 'ArrowLeft' || e.code === 'KeyA') { targetLane = Math.max(0, targetLane - 1); api.sfx('tick'); }
            else if (e.code === 'ArrowRight' || e.code === 'KeyD') { targetLane = Math.min(lanes - 1, targetLane + 1); api.sfx('tick'); }
        }
        document.addEventListener('keydown', key);

        api.setTag('FLOOR IT');
        api.startTimer(Math.max(11, 17 - diff), () => win());
        function fail() { if (done) return; done = true; document.removeEventListener('keydown', key); api.stopTimer(); api.shake(); api.sfx('bad'); setTimeout(() => api.fail(), 250); }
        function win() { if (done) return; done = true; document.removeEventListener('keydown', key); api.stopTimer(); api.setTag('CLEAR'); setTimeout(() => api.succeed(), 250); }

        function rr(x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }

        function draw() {
            if (!done) {
                carX += (laneX(targetLane) - carX) * 0.22;
                dash = (dash + speed) % 44;
                if (++spawnT >= spawnEvery) {
                    spawnT = 0;
                    const l = api.randInt(0, lanes - 1);
                    traffic.push({ x: laneX(l), y: -carH });
                    if (diff >= 3 && Math.random() < 0.45) {
                        const l2 = (l + 1 + api.randInt(0, lanes - 2)) % lanes;
                        traffic.push({ x: laneX(l2), y: -carH - api.rand(40, 110) });
                    }
                }
            }

            ctx.clearRect(0, 0, W, H);
            ctx.fillStyle = 'rgba(255,255,255,0.03)'; ctx.fillRect(0, 0, W, H);
            ctx.strokeStyle = 'rgba(255,255,255,0.14)'; ctx.lineWidth = 3;
            for (let i = 1; i < lanes; i++) { const x = (W / lanes) * i; for (let y = -44 + dash; y < H; y += 44) { ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x, y + 22); ctx.stroke(); } }

            let crash = false;
            for (const t of traffic) {
                if (!done) t.y += speed;
                ctx.fillStyle = dng; rr(t.x - carW / 2, t.y, carW, carH, 7); ctx.fill();
                ctx.fillStyle = 'rgba(0,0,0,0.35)'; rr(t.x - carW / 2 + 5, t.y + 9, carW - 10, 15, 3); ctx.fill();
                if (Math.abs(t.x - carX) < carW * 0.78 && t.y + carH > carY + 8 && t.y < carY + carH - 8) crash = true;
            }
            for (let i = traffic.length - 1; i >= 0; i--) if (traffic[i].y > H + 30) traffic.splice(i, 1);

            ctx.fillStyle = acc; ctx.shadowColor = acc; ctx.shadowBlur = 14; rr(carX - carW / 2, carY, carW, carH, 7); ctx.fill(); ctx.shadowBlur = 0;
            ctx.fillStyle = 'rgba(0,0,0,0.35)'; rr(carX - carW / 2 + 5, carY + 9, carW - 10, 15, 3); ctx.fill();

            if (crash && !done) { fail(); return; }
            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); } };
    }
});

// ── ghostsignal.js ──
MG.register('ghostsignal', {
    title: 'Ghost Signal',
    hint: '↑↓ frequency · ←→ phase · lock to match',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 480, H = 240;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const tol = Math.max(0.04, 0.16 - diff * 0.022);
        const noise = 4 + diff * 3;
        const targetF = api.rand(0.6, 2.2);
        const targetP = api.rand(0, Math.PI * 2);
        let f = api.rand(0.6, 2.2), p = api.rand(0, Math.PI * 2);
        let lockT = 0;
        const needLock = 55;

        api.startTimer(Math.max(12, 24 - diff * 2), () => { unbind(); api.fail(); });

        function key(e) {
            if (e.code === 'ArrowUp')    { f += 0.04; e.preventDefault(); }
            if (e.code === 'ArrowDown')  { f -= 0.04; e.preventDefault(); }
            if (e.code === 'ArrowLeft')  { p -= 0.12; e.preventDefault(); }
            if (e.code === 'ArrowRight') { p += 0.12; e.preventDefault(); }
            f = Math.max(0.4, Math.min(2.6, f));
        }
        document.addEventListener('keydown', key);
        function unbind() { document.removeEventListener('keydown', key); }

        function wave(fr, ph, amp, color, glow) {
            ctx.strokeStyle = color; ctx.lineWidth = 2;
            ctx.shadowColor = glow ? color : 'transparent'; ctx.shadowBlur = glow ? 10 : 0;
            ctx.beginPath();
            for (let x = 0; x <= W; x += 2) {
                const t = (x / W) * Math.PI * 6;
                const y = H / 2 - Math.sin(t * fr + ph) * amp
                    + (glow ? 0 : (Math.random() - 0.5) * noise);
                x ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
            }
            ctx.stroke(); ctx.shadowBlur = 0;
        }

        function draw() {
            ctx.clearRect(0, 0, W, H);
            wave(targetF, targetP, 60, 'rgba(255,255,255,0.22)', false);
            const acc = getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8';
            wave(f, p, 60, acc, true);

            const df = Math.abs(f - targetF);
            let dp = Math.abs(((p - targetP) % (Math.PI * 2)));
            dp = Math.min(dp, Math.PI * 2 - dp) / Math.PI;
            const locked = df < tol && dp < tol;

            if (locked) { lockT++; api.setTag('LOCKING ' + Math.round(lockT / needLock * 100) + '%'); }
            else { lockT = Math.max(0, lockT - 2); api.setTag('SCANNING'); }

            ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(20, H - 14, W - 40, 6);
            ctx.fillStyle = acc; ctx.fillRect(20, H - 14, (W - 40) * (lockT / needLock), 6);

            if (lockT >= needLock) { api.stopTimer(); unbind(); setTimeout(() => api.succeed(), 200); return; }
            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); unbind(); } };
    }
});

// ── harvest.js ──
MG.register('harvest', {
    title: 'Harvest',
    hint: 'SPACE / click as each crop crosses the cut line',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 360, H = 320, cutY = H - 60;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const total = 8 + diff * 2;
        const speed = 1.4 + diff * 0.7;
        const gap = Math.max(34, 64 - diff * 6);
        const needPct = 0.65 + diff * 0.04;
        const window_ = Math.max(22, 44 - diff * 3);

        let crops = [], spawned = 0, cut = 0, judged = 0, frame = 0, ended = false, flash = 0;

        function attempt() {
            if (ended) return;
            flash = 6;
            let best = null, bestD = 999;
            crops.forEach((c) => {
                if (!c.cut && !c.missed) { const d = Math.abs(c.y - cutY); if (d < bestD) { bestD = d; best = c; } }
            });
            if (best && bestD < window_) { best.cut = true; cut++; judged++; api.sfx('select'); }
            checkEnd();
        }
        function key(e) { if (e.code === 'Space') { e.preventDefault(); attempt(); } }
        document.addEventListener('keydown', key);
        cvs.addEventListener('click', attempt);

        function checkEnd() {
            if (judged >= total) {
                api.setTag(Math.round(cut / total * 100) + '%');
                finish((cut / total) >= needPct);
            }
        }
        api.setTag('HARVEST');
        api.startTimer(Math.max(14, 26 - diff), () => finish((cut / total) >= needPct));
        function finish(ok) { if (ended) return; ended = true; document.removeEventListener('keydown', key); api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 250); }

        function draw() {
            frame++;
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff3b5c').trim();
            if (!ended && spawned < total && frame % gap === 0) {
                crops.push({ x: api.rand(60, W - 60), y: -20, cut: false, missed: false }); spawned++;
            }
            ctx.clearRect(0, 0, W, H);
            ctx.strokeStyle = flash > 0 ? suc : acc; ctx.lineWidth = flash > 0 ? 4 : 2;
            ctx.shadowColor = acc; ctx.shadowBlur = flash > 0 ? 14 : 4;
            ctx.beginPath(); ctx.moveTo(0, cutY); ctx.lineTo(W, cutY); ctx.stroke(); ctx.shadowBlur = 0;
            if (flash > 0) flash--;

            crops.forEach((c) => {
                if (c.cut) return;
                if (!ended) c.y += speed;
                if (c.y > cutY + window_ && !c.missed) { c.missed = true; judged++; }
                ctx.fillStyle = c.missed ? dng : suc;
                ctx.shadowColor = ctx.fillStyle; ctx.shadowBlur = c.missed ? 0 : 6;
                ctx.beginPath();
                ctx.moveTo(c.x, c.y - 14); ctx.lineTo(c.x + 6, c.y); ctx.lineTo(c.x, c.y + 8); ctx.lineTo(c.x - 6, c.y);
                ctx.closePath(); ctx.fill(); ctx.shadowBlur = 0;
                ctx.strokeStyle = 'rgba(255,255,255,0.3)'; ctx.beginPath(); ctx.moveTo(c.x, c.y + 8); ctx.lineTo(c.x, c.y + 18); ctx.stroke();
            });
            crops = crops.filter((c) => c.y < H + 30 && !c.cut);
            checkEnd();
            if (!ended) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); } };
    }
});

// ── hottrace.js ──
MG.register('hottrace', {
    title: 'Hot Trace',
    hint: 'Drag the probe to the end · don’t touch the walls',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 480, H = 280;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'crosshair';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const halfW = Math.max(11, 26 - diff * 3);
        const segs = 6 + diff;
        const pts = [];
        for (let i = 0; i <= segs; i++) {
            const x = 30 + (W - 60) * (i / segs);
            const y = H / 2 + Math.sin(i * 0.9 + diff) * (H / 2 - 50) * (i === 0 || i === segs ? 0 : 1);
            pts.push({ x, y });
        }
        const start = pts[0], end = pts[pts.length - 1];

        let probe = { x: start.x, y: start.y };
        let holding = false, strikes = 0, won = false, lost = false;
        const maxStrikes = Math.max(2, 5 - diff);
        let progress = 0;

        function distToCorridor(px, py) {
            let best = 1e9;
            for (let i = 0; i < pts.length - 1; i++) {
                best = Math.min(best, segDist(px, py, pts[i], pts[i + 1]));
            }
            return best;
        }
        function segDist(px, py, a, b) {
            const dx = b.x - a.x, dy = b.y - a.y;
            const len2 = dx * dx + dy * dy || 1;
            let t = ((px - a.x) * dx + (py - a.y) * dy) / len2;
            t = Math.max(0, Math.min(1, t));
            const cx = a.x + t * dx, cy = a.y + t * dy;
            return Math.hypot(px - cx, py - cy);
        }
        function rel(e) {
            const b = cvs.getBoundingClientRect();
            return { x: (e.clientX - b.left) * (cvs.width / b.width),
                     y: (e.clientY - b.top) * (cvs.height / b.height) };
        }

        cvs.addEventListener('mousedown', (e) => {
            const p = rel(e);
            if (Math.hypot(p.x - probe.x, p.y - probe.y) < 22) holding = true;
        });
        window.addEventListener('mouseup', up);
        function up() { holding = false; }
        cvs.addEventListener('mousemove', (e) => {
            if (!holding || won || lost) return;
            const p = rel(e);
            probe = p;
            const d = distToCorridor(p.x, p.y);
            if (d > halfW) {
                strikes++; api.shake(); holding = false;
                probe = nearestOnLine(p);
                if (strikes >= maxStrikes) { lost = true; api.stopTimer(); end_(false); }
            }
            if (Math.hypot(p.x - end.x, p.y - end.y) < 18) { won = true; api.stopTimer(); end_(true); }
        });
        function nearestOnLine(p) {
            let best = { x: start.x, y: start.y }, bd = 1e9;
            for (let i = 0; i < pts.length - 1; i++) {
                const a = pts[i], b = pts[i + 1];
                const dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy || 1;
                let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2; t = Math.max(0, Math.min(1, t));
                const cx = a.x + t * dx, cy = a.y + t * dy, d = Math.hypot(p.x - cx, p.y - cy);
                if (d < bd) { bd = d; best = { x: cx, y: cy }; }
            }
            return best;
        }
        function end_(ok) {
            window.removeEventListener('mouseup', up);
            setTimeout(() => ok ? api.succeed() : api.fail(), 300);
        }

        api.setTag('TRACING');
        api.startTimer(Math.max(12, 24 - diff * 2), () => { if (!won && !lost) end_(false); });

        function draw() {
            ctx.clearRect(0, 0, W, H);
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff3b5c').trim();

            ctx.strokeStyle = 'rgba(255,255,255,0.06)'; ctx.lineWidth = halfW * 2; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
            ctx.beginPath(); pts.forEach((p, i) => i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)); ctx.stroke();
            ctx.strokeStyle = 'rgba(255,255,255,0.18)'; ctx.lineWidth = 1.5;
            ctx.beginPath(); pts.forEach((p, i) => i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)); ctx.stroke();

            ctx.fillStyle = acc; ctx.beginPath(); ctx.arc(start.x, start.y, 9, 0, Math.PI * 2); ctx.fill();
            ctx.fillStyle = suc; ctx.shadowColor = suc; ctx.shadowBlur = 12;
            ctx.beginPath(); ctx.arc(end.x, end.y, 11, 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0;

            ctx.fillStyle = holding ? acc : '#fff';
            ctx.shadowColor = acc; ctx.shadowBlur = holding ? 14 : 4;
            ctx.beginPath(); ctx.arc(probe.x, probe.y, 8, 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0;

            for (let i = 0; i < maxStrikes; i++) {
                ctx.fillStyle = i < strikes ? dng : 'rgba(255,255,255,0.15)';
                ctx.beginPath(); ctx.arc(20 + i * 16, 18, 5, 0, Math.PI * 2); ctx.fill();
            }
            if (!holding && !won && !lost) {
                ctx.fillStyle = 'rgba(255,255,255,0.4)'; ctx.font = '12px monospace'; ctx.textAlign = 'center';
                ctx.fillText('grab the probe at start', W / 2, H - 12);
            }
            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); window.removeEventListener('mouseup', up); } };
    }
});

// ── intrusion.js ──
MG.register('intrusion', {
    title: 'Intrusion',
    hint: 'Click a connected node to hop · avoid red (monitored) nodes',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 480, H = 300;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const cols = 4 + Math.floor(diff / 2);
        const nodes = [];
        const colX = [];
        for (let c = 0; c < cols; c++) {
            const x = 40 + (W - 80) * (c / (cols - 1));
            colX.push(x);
            const count = c === 0 || c === cols - 1 ? 1 : api.randInt(2, 3);
            for (let i = 0; i < count; i++) {
                const y = count === 1 ? H / 2 : 50 + (H - 100) * (i / (count - 1));
                nodes.push({ x, y, col: c, monitored: false, phase: Math.random() * Math.PI * 2 });
            }
        }
        const start = nodes.find((n) => n.col === 0);
        const server = nodes.find((n) => n.col === cols - 1);

        const edges = [];
        for (let c = 0; c < cols - 1; c++) {
            const a = nodes.filter((n) => n.col === c);
            const b = nodes.filter((n) => n.col === c + 1);
            a.forEach((na) => b.forEach((nb) => edges.push([na, nb])));
        }
        function neighbors(n) {
            return edges.filter((e) => e[0] === n || e[1] === n)
                        .map((e) => e[0] === n ? e[1] : e[0])
                        .filter((m) => m.col === n.col + 1);
        }

        const mid = nodes.filter((n) => n.col > 0 && n.col < cols - 1);
        const monCount = Math.min(mid.length, 1 + diff);
        mid.sort(() => Math.random() - 0.5).slice(0, monCount).forEach((n) => n.monitored = true);
        const pulseSpeed = 0.02 + diff * 0.006;

        let pos = start, won = false, lost = false, t = 0;

        function isRed(n) {
            return n.monitored && Math.sin(t * 60 * pulseSpeed * 0.05 + n.phase) > 0.2;
        }
        function red(n) { return n.monitored && (Math.sin(n.phase + t * pulseSpeed) > 0.15); }

        function rel(e) {
            const b = cvs.getBoundingClientRect();
            return { x: (e.clientX - b.left) * (cvs.width / b.width),
                     y: (e.clientY - b.top) * (cvs.height / b.height) };
        }
        cvs.addEventListener('click', (e) => {
            if (won || lost) return;
            const p = rel(e);
            const target = neighbors(pos).find((n) => Math.hypot(n.x - p.x, n.y - p.y) < 22);
            if (!target) return;
            if (red(target)) { lost = true; api.shake(); end_(false); return; }
            pos = target;
            if (pos === server) { won = true; end_(true); }
        });
        function end_(ok) { api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 300); }

        api.setTag('INTRUDING');
        api.startTimer(Math.max(14, 28 - diff * 2), () => { if (!won && !lost) end_(false); });

        function draw() {
            t += 1;
            ctx.clearRect(0, 0, W, H);
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff3b5c').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();

            edges.forEach((e) => {
                const reachable = e[0] === pos;
                ctx.strokeStyle = reachable ? acc : 'rgba(255,255,255,0.08)';
                ctx.lineWidth = reachable ? 2 : 1;
                ctx.beginPath(); ctx.moveTo(e[0].x, e[0].y); ctx.lineTo(e[1].x, e[1].y); ctx.stroke();
            });
            nodes.forEach((n) => {
                const r = red(n);
                let col = 'rgba(255,255,255,0.2)';
                if (n === server) col = suc;
                else if (r) col = dng;
                else if (n.monitored) col = 'rgba(255,140,0,0.5)';
                const hop = neighbors(pos).includes(n);
                ctx.fillStyle = n === pos ? acc : '#0a0e14';
                ctx.strokeStyle = col; ctx.lineWidth = hop ? 3 : 2;
                ctx.shadowColor = col; ctx.shadowBlur = (r || n === server) ? 14 : (hop ? 10 : 0);
                ctx.beginPath(); ctx.arc(n.x, n.y, 14, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
                ctx.shadowBlur = 0;
                if (n === server) {
                    ctx.fillStyle = suc; ctx.font = '9px monospace'; ctx.textAlign = 'center';
                    ctx.fillText('SRV', n.x, n.y + 26);
                }
            });
            ctx.strokeStyle = acc; ctx.lineWidth = 2;
            ctx.beginPath(); ctx.arc(pos.x, pos.y, 19, 0, Math.PI * 2); ctx.stroke();

            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── jammer.js ──
MG.register('jammer', {
    title: 'Signal Jammer',
    hint: 'Jam each alarm channel when its bar peaks',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const channels = 3 + Math.floor(diff / 1.5);
        const W = 440, H = 260;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const chW = (W - 40) / channels;
        const peakLow = 80, peakHigh = 100;
        const chans = [];
        for (let i = 0; i < channels; i++) {
            chans.push({ level: api.rand(0, 40), speed: 0.8 + diff * 0.4 + Math.random() * 0.8, dir: 1, jammed: false });
        }
        let jammedCount = 0, ended = false, wrong = 0;
        const maxWrong = Math.max(2, 5 - diff);
        api.setDots(channels);

        function rel(e) {
            const b = cvs.getBoundingClientRect();
            const x = (e.clientX - b.left) * (cvs.width / b.width);
            return Math.floor((x - 20) / chW);
        }
        cvs.addEventListener('click', (e) => {
            if (ended) return;
            const idx = rel(e);
            if (idx < 0 || idx >= channels || chans[idx].jammed) return;
            const c = chans[idx];
            if (c.level >= peakLow && c.level <= peakHigh) {
                c.jammed = true; jammedCount++; api.sfx('zap');
                api.setDots(channels, Array.from({ length: channels }, (_, i) => i < jammedCount ? 'done' : ''));
                if (jammedCount >= channels) finish(true);
            } else { wrong++; api.shake(); if (wrong >= maxWrong) finish(false); }
        });

        api.setTag('JAMMING');
        api.startTimer(Math.max(13, 24 - diff * 2), () => finish(false));
        function finish(ok) { if (ended) return; ended = true; api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 250); }

        function draw() {
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff3b5c').trim();
            ctx.clearRect(0, 0, W, H);
            const top = 30, bh = H - 80;
            chans.forEach((c, i) => {
                const x = 20 + i * chW + 6, w = chW - 12;
                if (!ended && !c.jammed) {
                    c.level += c.dir * c.speed;
                    if (c.level > 100) { c.level = 100; c.dir = -1; }
                    if (c.level < 0) { c.level = 0; c.dir = 1; }
                }
                ctx.fillStyle = 'rgba(255,255,255,0.06)'; ctx.fillRect(x, top, w, bh);
                ctx.fillStyle = 'rgba(57,217,138,0.18)';
                ctx.fillRect(x, top + bh * (1 - peakHigh / 100), w, bh * (peakHigh - peakLow) / 100);
                const lvl = c.jammed ? 0 : c.level;
                const fh = bh * lvl / 100;
                ctx.fillStyle = c.jammed ? suc : (lvl >= peakLow ? acc : 'rgba(255,140,0,0.7)');
                ctx.shadowColor = ctx.fillStyle; ctx.shadowBlur = (lvl >= peakLow || c.jammed) ? 12 : 0;
                ctx.fillRect(x, top + bh - fh, w, fh); ctx.shadowBlur = 0;
                ctx.fillStyle = c.jammed ? suc : 'rgba(255,255,255,0.5)'; ctx.font = '10px monospace'; ctx.textAlign = 'center';
                ctx.fillText(c.jammed ? 'JAMMED' : ('CH' + (i + 1)), x + w / 2, H - 34);
            });
            for (let i = 0; i < maxWrong; i++) {
                ctx.fillStyle = i < wrong ? dng : 'rgba(255,255,255,0.15)';
                ctx.beginPath(); ctx.arc(20 + i * 14, H - 14, 4, 0, Math.PI * 2); ctx.fill();
            }
            ctx.fillStyle = 'rgba(255,255,255,0.4)'; ctx.font = '11px monospace'; ctx.textAlign = 'center';
            ctx.fillText('click a channel at its peak (green band)', W / 2, 16);
            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── locksmith.js ──
MG.register('locksmith', {
    title: 'Locksmith',
    hint: 'Raise each pin to the shear line · SPACE to set',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const pinCount = 3 + Math.floor(diff / 1.3);
        const tol = Math.max(5, 12 - diff * 1.4);
        const W = 360, H = 260;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const shearY = 90;
        const pins = [];
        const pinW = (W - 80) / pinCount;
        for (let i = 0; i < pinCount; i++) {
            pins.push({ x: 40 + pinW * (i + 0.5), target: api.randInt(40, 150), h: 0, set: false });
        }
        let cur = 0, dir = 1, ended = false;
        api.setDots(pinCount);

        function attempt() {
            if (ended || cur >= pinCount) return;
            const p = pins[cur];
            if (Math.abs(p.h - p.target) < tol) {
                p.set = true; p.h = p.target; api.sfx('latch');
                api.setDots(pinCount, pins.map((x) => x.set ? 'done' : ''));
                cur++;
                if (cur >= pinCount) { finish(true); }
            } else { api.shake(); p.h = 0; }
        }
        function key(e) { if (e.code === 'Space') { e.preventDefault(); attempt(); } }
        document.addEventListener('keydown', key);
        cvs.addEventListener('click', attempt);

        api.setTag('PICKING');
        api.startTimer(Math.max(14, 26 - diff * 2), () => finish(false));
        function finish(ok) { if (ended) return; ended = true; document.removeEventListener('keydown', key); api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 250); }

        const riseSpeed = 1.6 + diff * 0.5;
        function draw() {
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            if (!ended && cur < pinCount) {
                const p = pins[cur];
                p.h += dir * riseSpeed;
                if (p.h > 170) { p.h = 170; dir = -1; }
                if (p.h < 0) { p.h = 0; dir = 1; }
            }
            ctx.clearRect(0, 0, W, H);
            ctx.strokeStyle = acc; ctx.lineWidth = 2; ctx.setLineDash([6, 5]);
            ctx.beginPath(); ctx.moveTo(20, shearY); ctx.lineTo(W - 20, shearY); ctx.stroke(); ctx.setLineDash([]);
            ctx.fillStyle = acc; ctx.font = '10px monospace'; ctx.textAlign = 'left';
            ctx.fillText('SHEAR LINE', 22, shearY - 6);

            pins.forEach((p, i) => {
                const baseY = H - 30;
                const isCur = i === cur && !ended;
                ctx.fillStyle = 'rgba(255,255,255,0.06)';
                ctx.fillRect(p.x - 12, shearY, 24, baseY - shearY);
                const topY = baseY - p.h;
                ctx.fillStyle = p.set ? suc : (isCur ? acc : 'rgba(255,255,255,0.25)');
                ctx.shadowColor = ctx.fillStyle; ctx.shadowBlur = isCur ? 12 : 0;
                ctx.fillRect(p.x - 9, topY, 18, baseY - topY);
                ctx.shadowBlur = 0;
                if (isCur) {
                    const tY = baseY - p.target;
                    ctx.strokeStyle = suc; ctx.lineWidth = 2;
                    ctx.beginPath(); ctx.moveTo(p.x - 14, tY); ctx.lineTo(p.x + 14, tY); ctx.stroke();
                }
            });
            ctx.fillStyle = 'rgba(255,255,255,0.4)'; ctx.font = '12px monospace'; ctx.textAlign = 'center';
            ctx.fillText('SPACE when the pin meets its mark', W / 2, H - 8);
            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); } };
    }
});

// ── mining.js ──
MG.register('mining', {
    title: 'Mining',
    hint: 'Click the glowing crack to strike · break the rock',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 360, H = 300;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const hitsNeeded = 4 + diff;
        const crackTime = Math.max(600, 1550 - diff * 170);
        let hits = 0, ended = false;
        let crack = null, crackBorn = 0, wrongStrikes = 0;
        const maxWrong = Math.max(2, 5 - diff);

        api.setDots(hitsNeeded);
        spawnCrack();

        function spawnCrack() {
            crack = { x: api.rand(70, W - 70), y: api.rand(70, H - 70) };
            crackBorn = performance.now();
        }
        function rel(e) {
            const b = cvs.getBoundingClientRect();
            return { x: (e.clientX - b.left) * (cvs.width / b.width),
                     y: (e.clientY - b.top) * (cvs.height / b.height) };
        }
        cvs.addEventListener('click', (e) => {
            if (ended || !crack) return;
            const p = rel(e);
            if (Math.hypot(p.x - crack.x, p.y - crack.y) < 28) {
                hits++;
                api.sfx('zap');
                api.setDots(hitsNeeded, Array.from({ length: hitsNeeded }, (_, i) => i < hits ? 'done' : ''));
                if (hits >= hitsNeeded) { finish(true); return; }
                spawnCrack();
            } else {
                wrongStrikes++; api.shake();
                if (wrongStrikes >= maxWrong) finish(false);
            }
        });

        api.setTag('MINING');
        api.startTimer(Math.max(12, 24 - diff * 2), () => finish(false));
        function finish(ok) { if (ended) return; ended = true; api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 250); }

        function draw() {
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            ctx.clearRect(0, 0, W, H);
            const g = ctx.createLinearGradient(0, 0, 0, H);
            g.addColorStop(0, 'rgba(255,255,255,0.06)'); g.addColorStop(1, 'rgba(255,255,255,0.02)');
            ctx.fillStyle = g; ctx.fillRect(20, 20, W - 40, H - 40);
            ctx.strokeStyle = 'rgba(255,255,255,0.1)';
            for (let i = 0; i < 8; i++) {
                ctx.beginPath();
                ctx.moveTo(api.randInt(20, W - 20) * 0 + (20 + i * (W - 40) / 8), 20);
                ctx.lineTo(20 + ((i + 0.5) * (W - 40) / 8), H - 20);
                ctx.globalAlpha = 0.04; ctx.stroke(); ctx.globalAlpha = 1;
            }
            if (crack && !ended) {
                const age = performance.now() - crackBorn;
                if (age > crackTime) { api.shake(); wrongStrikes++; if (wrongStrikes >= maxWrong) { finish(false); return; } spawnCrack(); }
                const pulse = 0.6 + Math.sin(age / 90) * 0.4;
                const r = 24 * (1 - age / crackTime) + 8;
                ctx.fillStyle = acc; ctx.globalAlpha = pulse; ctx.shadowColor = acc; ctx.shadowBlur = 18;
                ctx.beginPath(); ctx.arc(crack.x, crack.y, r, 0, Math.PI * 2); ctx.fill();
                ctx.globalAlpha = 1; ctx.shadowBlur = 0;
                ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5;
                for (let i = 0; i < 5; i++) {
                    const a = i / 5 * Math.PI * 2;
                    ctx.beginPath(); ctx.moveTo(crack.x, crack.y);
                    ctx.lineTo(crack.x + Math.cos(a) * r * 1.4, crack.y + Math.sin(a) * r * 1.4);
                    ctx.globalAlpha = pulse * 0.6; ctx.stroke(); ctx.globalAlpha = 1;
                }
            }
            for (let i = 0; i < maxWrong; i++) {
                ctx.fillStyle = i < wrongStrikes ? (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff3b5c').trim() : 'rgba(255,255,255,0.15)';
                ctx.beginPath(); ctx.arc(30 + i * 16, 12, 5, 0, Math.PI * 2); ctx.fill();
            }
            if (!ended) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── overflow.js ──
MG.register('overflow', {
    title: 'Overflow',
    hint: 'Click tiles to rotate · connect source → drain',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const N = 4 + Math.floor(diff / 2);
        const cell = Math.min(70, Math.floor(360 / N));
        const W = cell * N, H = cell * N;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const SHAPES = [
            [0, 2],
            [1, 3],
            [0, 1],
            [1, 2],
            [2, 3],
            [3, 0]
        ];
        const grid = [];
        for (let r = 0; r < N; r++) {
            grid[r] = [];
            for (let c = 0; c < N; c++) {
                grid[r][c] = { dirs: SHAPES[api.randInt(0, SHAPES.length - 1)].slice(), fill: 0 };
            }
        }
        const sr = Math.floor(N / 2), dr = Math.floor(N / 2);
        const source = { r: sr, c: 0, from: 3 };
        const drain  = { r: dr, c: N - 1, to: 1 };

        const opp = (d) => (d + 2) % 4;
        const step = [[ -1, 0], [0, 1], [1, 0], [0, -1]];

        function connected() {
            let cur = { r: source.r, c: source.c, enter: 3 };
            const seen = new Set();
            while (cur) {
                const key = cur.r + ',' + cur.c;
                if (seen.has(key)) return false;
                seen.add(key);
                const tile = grid[cur.r][cur.c];
                if (!tile.dirs.includes(cur.enter)) return false; // doesn't accept inflow
                const out = tile.dirs.find((d) => d !== cur.enter);
                if (out === undefined) return false;
                if (cur.r === drain.r && cur.c === drain.c && out === drain.to) return true;
                const ns = step[out];
                const nr = cur.r + ns[0], nc = cur.c + ns[1];
                if (nr < 0 || nr >= N || nc < 0 || nc >= N) return false;
                cur = { r: nr, c: nc, enter: opp(out) };
            }
            return false;
        }

        let locked = false;
        cvs.addEventListener('click', (e) => {
            if (locked) return;
            const b = cvs.getBoundingClientRect();
            const sx = cvs.width / b.width, sy = cvs.height / b.height;
            const x = (e.clientX - b.left) * sx, y = (e.clientY - b.top) * sy;
            const c = Math.floor(x / cell), r = Math.floor(y / cell);
            if (r < 0 || r >= N || c < 0 || c >= N) return;
            grid[r][c].dirs = grid[r][c].dirs.map((d) => (d + 1) % 4);
            if (connected()) {
                locked = true;
                api.stopTimer();
                api.setTag('SEALED');
                setTimeout(() => api.succeed(), 350);
            }
        });

        api.setTag('LEAKING');
        api.startTimer(Math.max(14, 34 - diff * 3), () => { if (!locked) api.fail(); });

        function drawTile(r, c) {
            const x = c * cell, y = r * cell, m = cell / 2;
            const cx = x + m, cy = y + m;
            ctx.strokeStyle = 'rgba(255,255,255,0.06)';
            ctx.strokeRect(x, y, cell, cell);
            const t = grid[r][c];
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            ctx.strokeStyle = acc; ctx.lineWidth = 6; ctx.lineCap = 'round';
            t.dirs.forEach((d) => {
                ctx.beginPath(); ctx.moveTo(cx, cy);
                if (d === 0) ctx.lineTo(cx, y);
                if (d === 1) ctx.lineTo(x + cell, cy);
                if (d === 2) ctx.lineTo(cx, y + cell);
                if (d === 3) ctx.lineTo(x, cy);
                ctx.stroke();
            });
            ctx.fillStyle = acc;
            ctx.beginPath(); ctx.arc(cx, cy, 4, 0, Math.PI * 2); ctx.fill();
        }

        function draw() {
            ctx.clearRect(0, 0, W, H);
            for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) drawTile(r, c);
            const sc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            ctx.fillStyle = sc;
            ctx.fillRect(0, source.r * cell + cell / 2 - 4, 8, 8);
            ctx.fillRect(W - 8, drain.r * cell + cell / 2 - 4, 8, 8);
            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── override.js ──
MG.register('override', {
    title: 'Override',
    hint: 'SPACE / click when the marker hits the top notch',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const ringCount = 2 + Math.floor(diff / 1.3);
        const W = 320, H = 320, cx = W / 2, cy = H / 2;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const rings = [];
        for (let i = 0; i < ringCount; i++) {
            rings.push({
                r: 50 + i * 38,
                ang: Math.random() * Math.PI * 2,
                spd: (0.02 + diff * 0.006) * (1 + i * 0.25) * (Math.random() < 0.5 ? 1 : -1),
                locked: false
            });
        }
        let active = ringCount - 1;
        const notch = -Math.PI / 2;
        const tol = Math.max(0.12, 0.3 - diff * 0.03);
        let corruption = 0;
        const corrSpeed = 0.0016 + diff * 0.0006;
        let done = false;

        api.setDots(ringCount);

        function attempt() {
            if (done || active < 0) return;
            const ring = rings[active];
            let d = Math.abs(((ring.ang - notch) % (Math.PI * 2)));
            d = Math.min(d, Math.PI * 2 - d);
            if (d < tol) {
                ring.locked = true; ring.ang = notch;
                const st = []; for (let i = 0; i < ringCount; i++)
                    st[i] = rings[i].locked ? 'done' : (i === active - 1 ? 'active' : '');
                api.setDots(ringCount, st.reverse());
                active--;
                if (active < 0) { done = true; api.stopTimer(); api.setTag('OVERRIDDEN'); setTimeout(() => api.succeed(), 400); }
            } else {
                api.shake();
                ring.spd *= 1.25;
                corruption = Math.min(1, corruption + 0.12);
            }
        }
        function key(e) { if (e.code === 'Space') { e.preventDefault(); attempt(); } }
        document.addEventListener('keydown', key);
        cvs.addEventListener('click', attempt);

        api.setTag('OVERRIDING');
        api.startTimer(Math.max(16, 34 - diff * 3), () => fail());
        function fail() { if (done) return; done = true; document.removeEventListener('keydown', key); api.stopTimer(); setTimeout(() => api.fail(), 200); }

        function draw() {
            if (!done) {
                corruption = Math.min(1, corruption + corrSpeed);
                if (corruption >= 1) { fail(); return; }
            }
            ctx.clearRect(0, 0, W, H);
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff3b5c').trim();

            ctx.fillStyle = 'rgba(255,255,255,0.06)';
            ctx.beginPath(); ctx.moveTo(cx, cy);
            ctx.arc(cx, cy, rings[ringCount - 1].r + 16, notch - tol, notch + tol); ctx.closePath(); ctx.fill();
            ctx.strokeStyle = acc; ctx.lineWidth = 2;
            ctx.beginPath(); ctx.moveTo(cx, cy - 30); ctx.lineTo(cx, cy - (rings[ringCount - 1].r + 20)); ctx.stroke();

            rings.forEach((ring, i) => {
                if (!ring.locked && !done) ring.ang += ring.spd;
                const isActive = i === active;
                ctx.strokeStyle = ring.locked ? suc : (isActive ? acc : 'rgba(255,255,255,0.15)');
                ctx.lineWidth = isActive ? 4 : 2;
                ctx.shadowColor = ring.locked ? suc : (isActive ? acc : 'transparent');
                ctx.shadowBlur = (ring.locked || isActive) ? 10 : 0;
                ctx.beginPath(); ctx.arc(cx, cy, ring.r, 0, Math.PI * 2); ctx.stroke();
                const ix = cx + Math.cos(ring.ang) * ring.r;
                const iy = cy + Math.sin(ring.ang) * ring.r;
                ctx.fillStyle = ring.locked ? suc : (isActive ? '#fff' : 'rgba(255,255,255,0.4)');
                ctx.beginPath(); ctx.arc(ix, iy, isActive ? 8 : 5, 0, Math.PI * 2); ctx.fill();
                ctx.shadowBlur = 0;
            });

            ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(40, H - 16, W - 80, 6);
            ctx.fillStyle = corruption > 0.7 ? dng : 'rgba(255,140,0,0.8)';
            ctx.fillRect(40, H - 16, (W - 80) * corruption, 6);

            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); } };
    }
});

// ── packing.js ──
MG.register('packing', {
    title: 'Crate Packing',
    hint: 'Drag every part into the crate so they all fit',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 440, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'grab';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();

        const cols = 5, rows = 3, cell = 34;
        const gx = (W - cols * cell) / 2, gy = 26;
        const occ = Array.from({ length: rows }, () => Array(cols).fill(-1));
        const maxPieces = 4 + Math.floor(diff / 2);

        // guillotine partition -> pieces (max 2x2) that exactly tile the grid (always solvable)
        const rects = [];
        (function part(x, y, w, h) {
            if (w > 2 || h > 2) {
                let vertical = (w > 2 && h <= 2) ? true : (h > 2 && w <= 2) ? false : (Math.random() < 0.5);
                if (vertical && w < 2) vertical = false;
                if (!vertical && h < 2) vertical = true;
                if (vertical) { const cut = 1 + Math.floor(Math.random() * (w - 1)); part(x, y, cut, h); part(x + cut, y, w - cut, h); }
                else { const cut = 1 + Math.floor(Math.random() * (h - 1)); part(x, y, w, cut); part(x, y + cut, w, h - cut); }
                return;
            }
            const canV = w >= 2, canH = h >= 2;
            if ((canV || canH) && rects.length < maxPieces - 1 && Math.random() < 0.4) {
                const vertical = canV && (!canH || Math.random() < 0.5);
                if (vertical) { part(x, y, 1, h); part(x + 1, y, w - 1, h); }
                else { part(x, y, w, 1); part(x, y + 1, w, h - 1); }
                return;
            }
            rects.push({ x, y, w, h });
        })(0, 0, cols, rows);

        const COLORS = ['#00e0b8', '#ffd23f', '#c06bff', '#39d98a', '#ff8a3d', '#4ad9ff', '#ff6b9d'];
        const pieces = rects.map((r, i) => ({ w: r.w, h: r.h, col: COLORS[i % COLORS.length], placed: false, gxc: -1, gyc: -1, px: 0, py: 0, hx: 0, hy: 0 }));

        // tidy tray layout below the crate (no overlap)
        const trayTop = gy + rows * cell + 24;
        let txp = 16, typ = trayTop, rh = 0;
        pieces.forEach(p => {
            const w = p.w * cell, h = p.h * cell;
            if (txp + w > W - 16) { txp = 16; typ += rh + 10; rh = 0; }
            p.px = p.hx = txp; p.py = p.hy = typ; txp += w + 12; rh = Math.max(rh, h);
        });

        let drag = null, off = { x: 0, y: 0 }, placedN = 0, done = false;
        api.setDots(pieces.length);
        function updateDots() { api.setDots(pieces.length, pieces.map(p => p.placed ? 'done' : '')); }

        function rel(e) { const b = cvs.getBoundingClientRect(); return { x: (e.clientX - b.left) * (W / b.width), y: (e.clientY - b.top) * (H / b.height) }; }
        function at(x, y) { for (let i = pieces.length - 1; i >= 0; i--) { const p = pieces[i]; if (x >= p.px && x <= p.px + p.w * cell && y >= p.py && y <= p.py + p.h * cell) return p; } return null; }
        function free(p) { if (p.gxc >= 0) { for (let r = 0; r < p.h; r++) for (let c = 0; c < p.w; c++) occ[p.gyc + r][p.gxc + c] = -1; p.gxc = p.gyc = -1; if (p.placed) { p.placed = false; placedN--; } } }
        cvs.addEventListener('mousedown', (e) => { const r = rel(e); const p = at(r.x, r.y); if (p) { drag = p; off.x = r.x - p.px; off.y = r.y - p.py; free(p); updateDots(); cvs.style.cursor = 'grabbing'; } });
        cvs.addEventListener('mousemove', (e) => { if (!drag) return; const r = rel(e); drag.px = r.x - off.x; drag.py = r.y - off.y; });
        function fitsAt(p, cgx, cgy) {
            if (cgx < 0 || cgy < 0 || cgx + p.w > cols || cgy + p.h > rows) return false;
            for (let r = 0; r < p.h; r++) for (let c = 0; c < p.w; c++) if (occ[cgy + r][cgx + c] !== -1) return false;
            return true;
        }
        function drop() {
            if (!drag) return; const p = drag; drag = null; cvs.style.cursor = 'grab';
            const cgx = Math.round((p.px - gx) / cell), cgy = Math.round((p.py - gy) / cell);
            if (fitsAt(p, cgx, cgy)) {
                const idx = pieces.indexOf(p);
                for (let r = 0; r < p.h; r++) for (let c = 0; c < p.w; c++) occ[cgy + r][cgx + c] = idx;
                p.gxc = cgx; p.gyc = cgy; p.px = gx + cgx * cell; p.py = gy + cgy * cell; p.placed = true; placedN++; api.sfx('latch'); updateDots();
                if (placedN >= pieces.length) { done = true; api.stopTimer(); api.setTag('PACKED'); setTimeout(() => api.succeed(), 300); }
            } else { p.px = p.hx; p.py = p.hy; api.sfx('tick'); }
        }
        cvs.addEventListener('mouseup', drop);
        cvs.addEventListener('mouseleave', drop);

        api.setTag('PACKING');
        api.startTimer(Math.max(22, 40 - diff * 3), () => { if (!done) { done = true; api.stopTimer(); setTimeout(() => api.fail(), 200); } });

        function drawPiece(p, dx, dy, alpha) {
            ctx.globalAlpha = alpha; ctx.fillStyle = p.col; ctx.strokeStyle = 'rgba(0,0,0,0.35)'; ctx.lineWidth = 1;
            for (let r = 0; r < p.h; r++) for (let c = 0; c < p.w; c++) { ctx.fillRect(dx + c * cell + 1, dy + r * cell + 1, cell - 2, cell - 2); ctx.strokeRect(dx + c * cell + 1, dy + r * cell + 1, cell - 2, cell - 2); }
            ctx.globalAlpha = 1;
        }
        function draw() {
            ctx.clearRect(0, 0, W, H);
            ctx.fillStyle = 'rgba(255,255,255,0.35)'; ctx.font = '10px monospace'; ctx.textAlign = 'left'; ctx.fillText('CRATE', gx, gy - 8);
            ctx.strokeStyle = 'rgba(255,255,255,0.12)'; ctx.lineWidth = 2; ctx.strokeRect(gx - 3, gy - 3, cols * cell + 6, rows * cell + 6);
            ctx.strokeStyle = 'rgba(255,255,255,0.06)'; ctx.lineWidth = 1;
            for (let c = 0; c <= cols; c++) { ctx.beginPath(); ctx.moveTo(gx + c * cell, gy); ctx.lineTo(gx + c * cell, gy + rows * cell); ctx.stroke(); }
            for (let r = 0; r <= rows; r++) { ctx.beginPath(); ctx.moveTo(gx, gy + r * cell); ctx.lineTo(gx + cols * cell, gy + r * cell); ctx.stroke(); }
            ctx.fillStyle = 'rgba(255,255,255,0.35)'; ctx.fillText('PARTS', 16, trayTop - 8);

            pieces.forEach(p => { if (p !== drag) drawPiece(p, p.px, p.py, p.placed ? 1 : 0.9); });
            if (drag) {
                const cgx = Math.round((drag.px - gx) / cell), cgy = Math.round((drag.py - gy) / cell);
                if (fitsAt(drag, cgx, cgy)) { ctx.fillStyle = 'rgba(57,217,138,0.2)'; ctx.fillRect(gx + cgx * cell, gy + cgy * cell, drag.w * cell, drag.h * cell); }
                drawPiece(drag, drag.px, drag.py, 0.95);
            }
            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── paintspray.js ──
MG.register('paintspray', {
    title: 'Paint Booth',
    hint: 'Hold mouse to spray · cover the panel evenly · don’t over-soak',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 420, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'crosshair';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();
        const accRGB = (() => { const h = acc.replace('#', ''); return [parseInt(h.substr(0, 2), 16), parseInt(h.substr(2, 2), 16), parseInt(h.substr(4, 2), 16)]; })();

        const cols = 14, rows = 10;
        const px = 40, py = 22, pw = W - 80, ph = H - 78;
        const cw = pw / cols, ch = ph / rows;
        const cells = new Float32Array(cols * rows);
        let spraying = false, mx = 0, my = 0, has = false, drips = 0, done = false;
        const need = Math.floor(cols * rows * 0.88);
        const dripLimit = Math.max(6, 16 - diff * 2);
        const brush = 2.0;
        const flow = 0.05 + diff * 0.006;

        cvs.addEventListener('mousemove', (e) => { const b = cvs.getBoundingClientRect(); mx = (e.clientX - b.left) * (W / b.width); my = (e.clientY - b.top) * (H / b.height); has = true; });
        cvs.addEventListener('mousedown', () => spraying = true);
        cvs.addEventListener('mouseup', () => spraying = false);
        cvs.addEventListener('mouseleave', () => spraying = false);

        api.setTag('PRIMING');
        api.startTimer(Math.max(18, 30 - diff * 2), () => fail('TIME'));
        function fail(m) { if (done) return; done = true; api.setTag(m || 'FAIL'); api.shake(); api.stopTimer(); setTimeout(() => api.fail(), 250); }
        function win() { if (done) return; done = true; api.setTag('GLOSS'); api.stopTimer(); setTimeout(() => api.succeed(), 300); }

        function bar(x, y, w, h, v, col, label) {
            ctx.fillStyle = 'rgba(255,255,255,0.08)'; ctx.fillRect(x, y, w, h);
            ctx.fillStyle = col; ctx.fillRect(x, y, w * Math.min(1, v), h);
            ctx.fillStyle = 'rgba(255,255,255,0.55)'; ctx.font = '9px monospace'; ctx.textAlign = 'left'; ctx.fillText(label, x, y - 3);
        }

        function draw() {
            if (!done && spraying && has) {
                const ccx = (mx - px) / cw, ccy = (my - py) / ch;
                for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
                    const d = Math.hypot(c + 0.5 - ccx, r + 0.5 - ccy);
                    if (d < brush) { const idx = r * cols + c; const before = cells[idx]; cells[idx] += flow * (1 - d / brush); if (cells[idx] > 1.25 && before <= 1.25) drips++; }
                }
            }

            ctx.clearRect(0, 0, W, H);
            ctx.strokeStyle = 'rgba(255,255,255,0.15)'; ctx.lineWidth = 2; ctx.strokeRect(px - 4, py - 4, pw + 8, ph + 8);

            let covered = 0;
            for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
                const v = cells[r * cols + c];
                if (v >= 0.6) covered++;
                if (v > 1.25) ctx.fillStyle = dng;
                else if (v >= 0.6) ctx.fillStyle = `rgba(${accRGB[0]},${accRGB[1]},${accRGB[2]},${0.25 + Math.min(1, v) * 0.6})`;
                else ctx.fillStyle = `rgba(255,255,255,${0.03 + v * 0.2})`;
                ctx.fillRect(px + c * cw + 0.5, py + r * ch + 0.5, cw - 1, ch - 1);
            }

            if (has) { ctx.strokeStyle = spraying ? acc : 'rgba(255,255,255,0.4)'; ctx.lineWidth = 2; ctx.beginPath(); ctx.arc(mx, my, brush * cw, 0, Math.PI * 2); ctx.stroke(); }

            const covPct = covered / (cols * rows);
            bar(px, H - 34, pw, 8, covPct, suc, 'COVERAGE ' + Math.round(covPct * 100) + '%');
            bar(px, H - 18, pw, 6, drips / dripLimit, dng, 'DRIPS ' + drips + '/' + dripLimit);

            if (!done) {
                if (drips >= dripLimit) { fail('TOO MANY DRIPS'); return; }
                if (covered >= need) { win(); return; }
                loop = requestAnimationFrame(draw);
            }
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── partsort.js ──
MG.register('partsort', {
    title: 'Parts Sort',
    hint: 'Send each part to its bin · press 1 / 2 / 3 (or click a bin)',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 420, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const BINS = [
            { name: 'NUTS', col: '#ffd23f', icon: 'hex' },
            { name: 'BOLTS', col: acc, icon: 'bolt' },
            { name: 'GEARS', col: '#c06bff', icon: 'gear' }
        ];
        const need = 7 + diff * 2;
        const maxWrong = Math.max(2, 5 - diff);
        let sorted = 0, wrong = 0, done = false, part = 0, fb = 0, fbCol = '';

        function spawn() { part = api.randInt(0, BINS.length - 1); }
        spawn();
        api.setDots(maxWrong);

        function choose(b) {
            if (done || b < 0 || b >= BINS.length) return;
            if (b === part) {
                sorted++; api.sfx('latch'); fb = 8; fbCol = suc;
                api.setTag(sorted + '/' + need);
                if (sorted >= need) { done = true; api.stopTimer(); api.setTag('SORTED'); document.removeEventListener('keydown', key); setTimeout(() => api.succeed(), 300); return; }
                spawn();
            } else {
                wrong++; api.shake(); fb = 8; fbCol = dng;
                api.setDots(maxWrong, Array.from({ length: maxWrong }, (_, i) => i < wrong ? 'fail' : ''));
                if (wrong >= maxWrong) { done = true; api.stopTimer(); document.removeEventListener('keydown', key); setTimeout(() => api.fail(), 300); }
            }
        }
        function key(e) {
            const n = { Digit1: 0, Digit2: 1, Digit3: 2 }[e.code];
            if (n != null && !done) { e.preventDefault(); choose(n); }
        }
        document.addEventListener('keydown', key);
        cvs.addEventListener('click', (e) => {
            const b = cvs.getBoundingClientRect();
            const x = (e.clientX - b.left) * (W / b.width), y = (e.clientY - b.top) * (H / b.height);
            if (y > H - 96) choose(Math.floor(x / (W / 3)));
        });

        api.setTag('0/' + need);
        api.startTimer(Math.max(16, 30 - diff * 2), () => { if (!done) { done = true; api.stopTimer(); document.removeEventListener('keydown', key); setTimeout(() => api.fail(), 200); } });

        function icon(shape, x, y, r, col) {
            ctx.strokeStyle = col; ctx.lineWidth = 2; ctx.lineCap = 'round';
            if (shape === 'hex') {
                ctx.beginPath();
                for (let k = 0; k < 6; k++) { const a = Math.PI / 6 + k * Math.PI / 3; const px = x + Math.cos(a) * r, py = y + Math.sin(a) * r; k ? ctx.lineTo(px, py) : ctx.moveTo(px, py); }
                ctx.closePath(); ctx.stroke();
                ctx.beginPath(); ctx.arc(x, y, r * 0.42, 0, Math.PI * 2); ctx.stroke();
            } else if (shape === 'bolt') {
                ctx.beginPath();
                for (let k = 0; k < 6; k++) { const a = Math.PI / 6 + k * Math.PI / 3; const px = x + Math.cos(a) * r * 0.7, py = y - r * 0.4 + Math.sin(a) * r * 0.7; k ? ctx.lineTo(px, py) : ctx.moveTo(px, py); }
                ctx.closePath(); ctx.stroke();
                ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x, y + r); ctx.stroke();
            } else {
                ctx.beginPath(); ctx.arc(x, y, r * 0.6, 0, Math.PI * 2); ctx.stroke();
                for (let k = 0; k < 8; k++) { const a = k * Math.PI / 4; ctx.beginPath(); ctx.moveTo(x + Math.cos(a) * r * 0.6, y + Math.sin(a) * r * 0.6); ctx.lineTo(x + Math.cos(a) * r, y + Math.sin(a) * r); ctx.stroke(); }
                ctx.beginPath(); ctx.arc(x, y, r * 0.2, 0, Math.PI * 2); ctx.stroke();
            }
        }
        function rr(x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }

        function draw() {
            if (fb > 0) fb--;
            ctx.clearRect(0, 0, W, H);

            ctx.fillStyle = 'rgba(255,255,255,0.45)'; ctx.font = '11px monospace'; ctx.textAlign = 'center';
            ctx.fillText('SORTED ' + sorted + ' / ' + need, W / 2, 20);

            const px = W / 2, py = 88;
            ctx.strokeStyle = 'rgba(255,255,255,0.1)'; ctx.lineWidth = 2;
            ctx.beginPath(); ctx.moveTo(px - 42, 34); ctx.lineTo(px - 42, py + 18); ctx.moveTo(px + 42, 34); ctx.lineTo(px + 42, py + 18); ctx.stroke();

            const b = BINS[part];
            ctx.save();
            ctx.shadowColor = fb > 0 ? fbCol : b.col; ctx.shadowBlur = fb > 0 ? 20 : 12;
            ctx.fillStyle = 'rgba(255,255,255,0.04)';
            ctx.beginPath(); ctx.arc(px, py, 30, 0, Math.PI * 2); ctx.fill();
            ctx.restore();
            icon(b.icon, px, py, 20, fb > 0 ? fbCol : b.col);

            const bw = W / 3;
            BINS.forEach((bin, i) => {
                const bx = i * bw, byTop = H - 92;
                ctx.fillStyle = 'rgba(255,255,255,0.04)'; rr(bx + 8, byTop, bw - 16, 78, 8); ctx.fill();
                ctx.strokeStyle = bin.col; ctx.lineWidth = 2; rr(bx + 8, byTop, bw - 16, 78, 8); ctx.stroke();
                icon(bin.icon, bx + bw / 2, byTop + 28, 14, bin.col);
                ctx.fillStyle = bin.col; ctx.font = 'bold 11px monospace'; ctx.textAlign = 'center';
                ctx.fillText(bin.name, bx + bw / 2, byTop + 58);
                ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '10px monospace';
                ctx.fillText('[' + (i + 1) + ']', bx + bw / 2, byTop + 72);
            });

            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); } };
    }
});

// ── pillpress.js ──
MG.register('pillpress', {
    title: 'Pill Press',
    hint: 'SPACE / click when the press is fully down on the die',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 360, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const need = 4 + diff;
        const maxWrong = Math.max(2, 5 - diff);
        const window = Math.max(0.1, 0.24 - diff * 0.025);
        let phase = 0, spd = 0.03 + diff * 0.006, made = 0, wrong = 0, done = false, flash = 0;

        api.setDots(need);

        function press() {
            if (done) return;
            const pos = (1 - Math.cos(phase)) / 2; // 0 top .. 1 bottom
            if (pos >= 1 - window) {
                made++; api.sfx('latch'); flash = 6; spd += 0.002;
                api.setDots(need, Array.from({ length: need }, (_, i) => i < made ? 'done' : ''));
                if (made >= need) { done = true; api.stopTimer(); api.setTag('PRESSED'); setTimeout(() => api.succeed(), 300); }
            } else {
                wrong++; api.shake();
                if (wrong >= maxWrong) { done = true; api.stopTimer(); setTimeout(() => api.fail(), 300); }
            }
        }
        function key(e) { if (e.code === 'Space') { e.preventDefault(); press(); } }
        document.addEventListener('keydown', key);
        cvs.addEventListener('click', press);

        api.setTag('PRESSING');
        api.startTimer(Math.max(16, 28 - diff * 2), () => { if (!done) { done = true; api.stopTimer(); document.removeEventListener('keydown', key); setTimeout(() => api.fail(), 200); } });

        function draw() {
            if (!done) phase += spd;
            const pos = (1 - Math.cos(phase)) / 2;
            ctx.clearRect(0, 0, W, H);

            const cx = W / 2, topY = 40, travel = 120, dieY = topY + travel + 26;
            // frame posts
            ctx.strokeStyle = 'rgba(255,255,255,0.15)'; ctx.lineWidth = 6;
            ctx.beginPath(); ctx.moveTo(cx - 70, 30); ctx.lineTo(cx - 70, dieY + 20); ctx.moveTo(cx + 70, 30); ctx.lineTo(cx + 70, dieY + 20); ctx.stroke();
            // die / target zone
            const inWin = pos >= 1 - window;
            ctx.fillStyle = 'rgba(57,217,138,0.15)'; ctx.fillRect(cx - 46, dieY - 6, 92, 14);
            ctx.strokeStyle = inWin ? suc : 'rgba(57,217,138,0.5)'; ctx.lineWidth = 2; ctx.strokeRect(cx - 46, dieY - 6, 92, 14);
            // press head
            const hy = topY + travel * pos;
            ctx.fillStyle = flash > 0 ? suc : acc; ctx.shadowColor = ctx.fillStyle; ctx.shadowBlur = inWin ? 16 : 6;
            ctx.fillRect(cx - 40, hy - 30, 80, 30); ctx.shadowBlur = 0;
            if (flash > 0) flash--;

            // pills made
            for (let i = 0; i < need; i++) {
                ctx.fillStyle = i < made ? suc : 'rgba(255,255,255,0.12)';
                ctx.beginPath(); ctx.ellipse(cx - (need - 1) * 9 + i * 18, dieY + 40, 7, 4, 0, 0, Math.PI * 2); ctx.fill();
            }
            // strike dots
            for (let i = 0; i < maxWrong; i++) { ctx.fillStyle = i < wrong ? dng : 'rgba(255,255,255,0.15)'; ctx.beginPath(); ctx.arc(20 + i * 14, 24, 4, 0, Math.PI * 2); ctx.fill(); }

            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); } };
    }
});

// ── resonance.js ──
MG.register('resonance', {
    title: 'Resonance',
    hint: 'Tune the sliders so your wave matches the target',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const comps = 2 + Math.floor(diff / 1.5);
        const tol = Math.max(0.06, 0.16 - diff * 0.02);
        const W = 480, H = 180;

        const parts = [];
        for (let i = 0; i < comps; i++) {
            parts.push({
                freq: 1 + i * 0.8 + api.rand(-0.2, 0.2),
                sign: i === comps - 1 && diff >= 3 ? -1 : 1,
                target: api.rand(0.2, 1),
                cur: api.rand(0, 1)
            });
        }

        const box = document.createElement('div');
        box.style.cssText = 'display:flex;flex-direction:column;gap:14px;width:480px;';
        box.innerHTML = `
            <canvas id="wv" width="${W}" height="${H}" style="border:1px solid var(--line);border-radius:8px;background:rgba(0,0,0,.25);"></canvas>
            <div id="match" class="label" style="text-align:center;">MATCH: 0%</div>
            <div id="sliders" style="display:flex;flex-direction:column;gap:10px;"></div>`;
        api.board.appendChild(box);
        const cvs = box.querySelector('#wv');
        const ctx = cvs.getContext('2d');
        const slBox = box.querySelector('#sliders');
        const matchEl = box.querySelector('#match');

        parts.forEach((p, i) => {
            const row = document.createElement('div');
            row.style.cssText = 'display:flex;align-items:center;gap:12px;';
            row.innerHTML = `
                <span style="width:74px;font-size:11px;color:${p.sign < 0 ? 'var(--danger)' : 'var(--muted)'};">
                    ${p.sign < 0 ? 'INVERT ' : 'NODE '}${i + 1}</span>
                <input type="range" min="0" max="100" value="${Math.round(p.cur * 100)}"
                    style="flex:1;accent-color:${p.sign < 0 ? 'var(--danger)' : 'var(--accent)'};">`;
            const slider = row.querySelector('input');
            slider.addEventListener('input', () => { p.cur = slider.value / 100; });
            slBox.appendChild(row);
        });

        function waveAt(x, useTarget) {
            const t = (x / W) * Math.PI * 4;
            let y = 0;
            parts.forEach((p) => {
                const amp = useTarget ? p.target : p.cur;
                y += p.sign * amp * Math.sin(t * p.freq);
            });
            return y;
        }
        function matchPct() {
            let err = 0;
            parts.forEach((p) => { err += Math.abs(p.cur - p.target); });
            const norm = err / parts.length;
            return Math.max(0, 1 - norm);
        }

        let solved = false;
        api.setTag('CALIBRATING');
        api.startTimer(Math.max(16, 38 - diff * 3), () => { if (!solved) api.fail(); });

        function plot(useTarget, color, glow) {
            ctx.strokeStyle = color; ctx.lineWidth = 2;
            ctx.shadowColor = glow ? color : 'transparent'; ctx.shadowBlur = glow ? 8 : 0;
            ctx.beginPath();
            const scale = H / 2 / (parts.length + 0.5);
            for (let x = 0; x <= W; x += 2) {
                const y = H / 2 - waveAt(x, useTarget) * scale;
                x ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
            }
            ctx.stroke(); ctx.shadowBlur = 0;
        }
        function draw() {
            ctx.clearRect(0, 0, W, H);
            ctx.strokeStyle = 'rgba(255,255,255,0.06)';
            ctx.beginPath(); ctx.moveTo(0, H / 2); ctx.lineTo(W, H / 2); ctx.stroke();
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            plot(true, 'rgba(255,255,255,0.28)', false);   // target ghost
            plot(false, acc, true);

            const m = matchPct();
            matchEl.textContent = 'MATCH: ' + Math.round(m * 100) + '%';
            matchEl.style.color = m > 0.92 ? 'var(--success)' : 'var(--muted)';

            if (!solved && (1 - m) < tol) {
                solved = true; api.stopTimer(); api.setTag('LOCKED');
                setTimeout(() => api.succeed(), 400);
                return;
            }
            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── steadydose.js ──
MG.register('steadydose', {
    title: 'Steady Dose',
    hint: 'Move mouse · keep the needle in the band',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 360, H = 300;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'ns-resize';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const zoneH = Math.max(34, 80 - diff * 9);
        const zoneSpeed = 0.8 + diff * 0.5;
        const tremor = diff * 0.9;
        let zoneY = H / 2, zdir = 1, phase = 0;
        let needle = H / 2, fill = 0;

        api.startTimer(Math.max(10, 20 - diff), () => { unbind(); api.fail(); });

        function move(e) {
            const b = cvs.getBoundingClientRect();
            const sy = cvs.height / b.height;
            needle = Math.max(20, Math.min(H - 20, (e.clientY - b.top) * sy));
        }
        cvs.addEventListener('mousemove', move);
        function unbind() { cvs.removeEventListener('mousemove', move); }

        function draw() {
            phase += 0.04;
            zoneY += zdir * zoneSpeed * (1 + Math.sin(phase) * 0.4);
            if (zoneY < zoneH / 2 + 20) zdir = 1;
            if (zoneY > H - zoneH / 2 - 20) zdir = -1;

            const wob = Math.sin(phase * 5) * tremor;
            const nY = needle + wob;
            const inside = nY > zoneY - zoneH / 2 && nY < zoneY + zoneH / 2;
            fill += inside ? 0.9 : -1.3;
            fill = Math.max(0, Math.min(100, fill));
            if (!inside && tremor > 0) api.setTag('UNSTABLE'); else api.setTag('STABLE');

            if (fill >= 100) { api.stopTimer(); unbind(); setTimeout(() => api.succeed(), 200); return; }

            ctx.clearRect(0, 0, W, H);
            const trackX = W / 2 - 30;
            ctx.fillStyle = 'rgba(255,255,255,0.05)';
            ctx.fillRect(trackX, 20, 60, H - 40);
            const acc = getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8';
            ctx.fillStyle = inside ? 'rgba(57,217,138,0.25)' : 'rgba(0,224,184,0.12)';
            ctx.strokeStyle = inside ? '#39d98a' : acc; ctx.lineWidth = 2;
            ctx.fillRect(trackX, zoneY - zoneH / 2, 60, zoneH);
            ctx.strokeRect(trackX, zoneY - zoneH / 2, 60, zoneH);
            ctx.fillStyle = '#fff'; ctx.shadowColor = '#fff'; ctx.shadowBlur = 8;
            ctx.beginPath();
            ctx.moveTo(trackX - 14, nY); ctx.lineTo(trackX - 2, nY - 8); ctx.lineTo(trackX - 2, nY + 8);
            ctx.fill(); ctx.shadowBlur = 0;
            ctx.fillRect(trackX, nY - 1.5, 60, 3);

            ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(W - 26, 20, 10, H - 40);
            ctx.fillStyle = acc;
            const fh = (H - 40) * (fill / 100);
            ctx.fillRect(W - 26, 20 + (H - 40 - fh), 10, fh);

            loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); unbind(); } };
    }
});

// ── suture.js ──
MG.register('suture', {
    title: 'Suture',
    hint: 'Click each stitch when its ring shrinks into the green',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 400, H = 280;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();

        const N = 4 + Math.floor(diff / 2); // 4..6
        const x0 = 50, x1 = W - 50, yMid = H / 2;
        const stitches = [];
        for (let i = 0; i < N; i++) {
            const x = x0 + (x1 - x0) * ((i + 0.5) / N);
            stitches.push({ x, y: yMid + (i % 2 === 0 ? -26 : 26), done: false });
        }
        let idx = 0, ring = 1, dirR = -1, done = false;
        const ringSpd = 0.012 + diff * 0.003;
        const band = Math.max(0.1, 0.26 - diff * 0.03);
        const lo = 0.18, hi = lo + band;

        api.setDots(N);
        function attempt(cx, cy) {
            if (done) return;
            const s = stitches[idx];
            if (Math.hypot(cx - s.x, cy - s.y) < 42 && ring >= lo && ring <= hi) {
                s.done = true; idx++; api.sfx('latch');
                api.setDots(N, stitches.map(st => st.done ? 'done' : ''));
                ring = 1; dirR = -1;
                if (idx >= N) { done = true; api.stopTimer(); api.setTag('CLOSED'); setTimeout(() => api.succeed(), 300); }
            } else { api.shake(); api.addTime(-1500); }
        }
        cvs.addEventListener('click', (e) => { const b = cvs.getBoundingClientRect(); attempt((e.clientX - b.left) * (W / b.width), (e.clientY - b.top) * (H / b.height)); });

        api.setTag('SUTURING');
        api.startTimer(Math.max(16, 28 - diff * 2), () => { if (!done) { done = true; api.stopTimer(); setTimeout(() => api.fail(), 200); } });

        function draw() {
            if (!done) { ring += ringSpd * dirR; if (ring < lo - 0.12) dirR = 1; if (ring > 1) { ring = 1; dirR = -1; } }
            ctx.clearRect(0, 0, W, H);

            ctx.strokeStyle = 'rgba(255,80,90,0.55)'; ctx.lineWidth = 6; ctx.beginPath();
            for (let x = x0 - 10; x <= x1 + 10; x += 14) { const yy = yMid + Math.sin(x * 0.25) * 4; x === x0 - 10 ? ctx.moveTo(x, yy) : ctx.lineTo(x, yy); }
            ctx.stroke();

            ctx.strokeStyle = acc; ctx.lineWidth = 2;
            stitches.forEach(s => { if (s.done) { ctx.beginPath(); ctx.moveTo(s.x, yMid - 26); ctx.lineTo(s.x, yMid + 26); ctx.stroke(); } });

            stitches.forEach((s, i) => {
                ctx.fillStyle = s.done ? suc : (i === idx ? '#fff' : 'rgba(255,255,255,0.3)');
                ctx.beginPath(); ctx.arc(s.x, s.y, 4, 0, Math.PI * 2); ctx.fill();
            });

            if (!done && idx < N) {
                const s = stitches[idx], inB = ring >= lo && ring <= hi;
                ctx.strokeStyle = 'rgba(57,217,138,0.3)'; ctx.lineWidth = (hi - lo) * 30;
                ctx.beginPath(); ctx.arc(s.x, s.y, 6 + ((lo + hi) / 2) * 30, 0, Math.PI * 2); ctx.stroke();
                ctx.strokeStyle = inB ? suc : acc; ctx.lineWidth = 2;
                ctx.beginPath(); ctx.arc(s.x, s.y, 6 + ring * 30, 0, Math.PI * 2); ctx.stroke();
            }

            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── titration.js ──
MG.register('titration', {
    title: 'Titration',
    hint: 'Hold to pour · stop in the green band · don’t overshoot',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 360, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'pointer';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const rounds = 2 + Math.floor(diff / 2);
        const bandH = Math.max(0.05, 0.13 - diff * 0.012);
        const pourRate = 0.34 + diff * 0.06;
        let round = 0, level = 0, lo = 0, hi = 0, pour = false, done = false, last = performance.now();

        function newTarget() { lo = 0.45 + Math.random() * (0.92 - bandH - 0.45); hi = lo + bandH; level = 0; }
        newTarget();
        api.setDots(rounds);

        function release() {
            if (done || !pour) return; pour = false;
            if (level >= lo && level <= hi) {
                round++; api.sfx('good'); api.setDots(rounds, Array.from({ length: rounds }, (_, i) => i < round ? 'done' : ''));
                if (round >= rounds) { done = true; api.stopTimer(); api.setTag('TITRATED'); setTimeout(() => api.succeed(), 300); return; }
                newTarget();
            } else if (level > hi) { api.shake(); done = true; api.stopTimer(); api.setTag('OVERSHOT'); setTimeout(() => api.fail(), 300); }
            // under the band: stays, player may pour again
        }
        function down(e) { if (e.code === 'Space') { e.preventDefault(); pour = true; } }
        function up(e) { if (e.code === 'Space') { e.preventDefault(); release(); } }
        document.addEventListener('keydown', down);
        document.addEventListener('keyup', up);
        cvs.addEventListener('mousedown', () => pour = true);
        cvs.addEventListener('mouseup', release);
        cvs.addEventListener('mouseleave', release);

        api.setTag('POURING');
        api.startTimer(Math.max(16, 28 - diff * 2), () => { if (!done) { done = true; api.stopTimer(); document.removeEventListener('keydown', down); document.removeEventListener('keyup', up); setTimeout(() => api.fail(), 200); } });

        function draw() {
            const now = performance.now(); const dt = Math.min(0.05, (now - last) / 1000); last = now;
            if (!done && pour) {
                level = Math.min(1, level + pourRate * dt);
                if (level > hi + 0.001) release();
            }
            ctx.clearRect(0, 0, W, H);

            // burette dripping
            const bx = W / 2;
            ctx.strokeStyle = 'rgba(255,255,255,0.25)'; ctx.lineWidth = 2; ctx.strokeRect(bx - 8, 14, 16, 40);
            if (pour) { ctx.fillStyle = acc; ctx.beginPath(); ctx.arc(bx, 60 + (performance.now() / 60 % 14), 2.5, 0, Math.PI * 2); ctx.fill(); }

            // beaker
            const beX = bx - 70, beY = 84, beW = 140, beH = H - 120;
            ctx.fillStyle = (level >= lo && level <= hi) ? 'rgba(57,217,138,0.6)' : (level > hi ? 'rgba(255,59,92,0.6)' : 'rgba(0,224,184,0.5)');
            ctx.fillRect(beX, beY + beH * (1 - level), beW, beH * level);
            // target band
            ctx.fillStyle = 'rgba(57,217,138,0.18)'; ctx.fillRect(beX, beY + beH * (1 - hi), beW, beH * (hi - lo));
            ctx.strokeStyle = suc; ctx.lineWidth = 1.5; ctx.strokeRect(beX, beY + beH * (1 - hi), beW, beH * (hi - lo));
            ctx.strokeStyle = 'rgba(255,255,255,0.25)'; ctx.lineWidth = 2;
            ctx.beginPath(); ctx.moveTo(beX, beY); ctx.lineTo(beX, beY + beH); ctx.lineTo(beX + beW, beY + beH); ctx.lineTo(beX + beW, beY); ctx.stroke();

            ctx.fillStyle = 'rgba(255,255,255,0.45)'; ctx.font = '10px monospace'; ctx.textAlign = 'center';
            ctx.fillText('stop in the green band', bx, H - 14);
            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', down); document.removeEventListener('keyup', up); } };
    }
});

// ── toolbox.js ──
MG.register('toolbox', {
    title: 'Tool Board',
    hint: 'Drag each tool onto its matching outline',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 440, H = 300;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'grab';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();

        const TYPES = ['wrench', 'driver', 'hammer', 'pliers', 'spanner'];
        const N = 3 + Math.floor(diff / 1.5); // 3..5
        const types = TYPES.slice(0, N);
        const tol = 34;

        // shadow slots in a row on the board (shuffled type order)
        const slotTypes = types.slice();
        for (let i = slotTypes.length - 1; i > 0; i--) { const j = api.randInt(0, i); const t = slotTypes[i]; slotTypes[i] = slotTypes[j]; slotTypes[j] = t; }
        const slots = slotTypes.map((type, i) => ({ type, x: W * (i + 0.5) / N, y: 92, filled: false }));

        // loose tools in the tray (shuffled x positions so they don't line up)
        const homeXs = [];
        for (let i = 0; i < N; i++) homeXs.push(W * (i + 0.5) / N);
        for (let i = homeXs.length - 1; i > 0; i--) { const j = api.randInt(0, i); const t = homeXs[i]; homeXs[i] = homeXs[j]; homeXs[j] = t; }
        const tools = types.map((type, i) => ({ type, x: homeXs[i], y: H - 58, hx: homeXs[i], hy: H - 58, placed: false }));

        let drag = null, off = { x: 0, y: 0 }, placedN = 0, done = false;
        api.setDots(N);

        function rel(e) { const b = cvs.getBoundingClientRect(); return { x: (e.clientX - b.left) * (W / b.width), y: (e.clientY - b.top) * (H / b.height) }; }
        function at(x, y) { for (let i = tools.length - 1; i >= 0; i--) { const t = tools[i]; if (!t.placed && Math.abs(x - t.x) < 24 && Math.abs(y - t.y) < 22) return t; } return null; }
        cvs.addEventListener('mousedown', (e) => { const r = rel(e); const t = at(r.x, r.y); if (t) { drag = t; off.x = r.x - t.x; off.y = r.y - t.y; cvs.style.cursor = 'grabbing'; } });
        cvs.addEventListener('mousemove', (e) => { if (!drag) return; const r = rel(e); drag.x = r.x - off.x; drag.y = r.y - off.y; });
        function dropTool() {
            if (!drag) return; const t = drag; drag = null; cvs.style.cursor = 'grab';
            const s = slots.find(sl => !sl.filled && sl.type === t.type && Math.hypot(t.x - sl.x, t.y - sl.y) < tol);
            if (s) {
                s.filled = true; t.placed = true; t.x = s.x; t.y = s.y; placedN++; api.sfx('latch');
                api.setDots(N, tools.map(tt => tt.placed ? 'done' : ''));
                if (placedN >= N) { done = true; api.stopTimer(); api.setTag('STOCKED'); setTimeout(() => api.succeed(), 300); }
            } else { t.x = t.hx; t.y = t.hy; api.sfx('tick'); }
        }
        cvs.addEventListener('mouseup', dropTool);
        cvs.addEventListener('mouseleave', dropTool);

        api.setTag('ORGANIZE');
        api.startTimer(Math.max(18, 32 - diff * 2), () => { if (!done) { done = true; api.stopTimer(); setTimeout(() => api.fail(), 200); } });

        function drawTool(type, x, y, col, alpha) {
            ctx.save(); ctx.globalAlpha = alpha == null ? 1 : alpha; ctx.translate(x, y);
            ctx.strokeStyle = col; ctx.lineWidth = 3; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
            if (type === 'wrench') { ctx.rotate(-0.6); ctx.beginPath(); ctx.moveTo(-2, 16); ctx.lineTo(2, -6); ctx.stroke(); ctx.beginPath(); ctx.arc(2, -11, 7, Math.PI * 0.2, Math.PI * 1.8); ctx.stroke(); }
            else if (type === 'driver') { ctx.lineWidth = 6; ctx.beginPath(); ctx.moveTo(0, -16); ctx.lineTo(0, 2); ctx.stroke(); ctx.lineWidth = 3; ctx.beginPath(); ctx.moveTo(0, 2); ctx.lineTo(0, 16); ctx.stroke(); }
            else if (type === 'hammer') { ctx.beginPath(); ctx.moveTo(0, -2); ctx.lineTo(0, 18); ctx.stroke(); ctx.lineWidth = 7; ctx.beginPath(); ctx.moveTo(-11, -9); ctx.lineTo(11, -9); ctx.stroke(); }
            else if (type === 'pliers') { ctx.beginPath(); ctx.moveTo(-6, 18); ctx.lineTo(2, -1); ctx.lineTo(-3, -16); ctx.stroke(); ctx.beginPath(); ctx.moveTo(6, 18); ctx.lineTo(-2, -1); ctx.lineTo(3, -16); ctx.stroke(); }
            else { ctx.beginPath(); ctx.arc(0, -10, 7, 0, Math.PI * 2); ctx.stroke(); ctx.beginPath(); ctx.arc(0, -10, 3, 0, Math.PI * 2); ctx.stroke(); ctx.lineWidth = 5; ctx.beginPath(); ctx.moveTo(0, -3); ctx.lineTo(0, 18); ctx.stroke(); }
            ctx.restore(); ctx.globalAlpha = 1;
        }

        function draw() {
            ctx.clearRect(0, 0, W, H);
            ctx.strokeStyle = 'rgba(255,255,255,0.08)'; ctx.lineWidth = 1; ctx.strokeRect(16, 42, W - 32, 104);
            ctx.fillStyle = 'rgba(255,255,255,0.4)'; ctx.font = '10px monospace'; ctx.textAlign = 'left';
            ctx.fillText('SHADOW BOARD', 22, 56);
            ctx.fillText('TOOLS', 22, H - 78);

            slots.forEach(s => {
                if (!s.filled) {
                    drawTool(s.type, s.x, s.y, 'rgba(255,255,255,0.16)', 1);
                    ctx.setLineDash([4, 3]); ctx.strokeStyle = 'rgba(255,255,255,0.16)'; ctx.lineWidth = 1;
                    ctx.beginPath(); ctx.arc(s.x, s.y, tol - 6, 0, Math.PI * 2); ctx.stroke(); ctx.setLineDash([]);
                }
            });
            tools.forEach(t => { if (t !== drag) drawTool(t.type, t.x, t.y, t.placed ? suc : acc); });
            if (drag) drawTool(drag.type, drag.x, drag.y, acc);

            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); } };
    }
});

// ── vitals.js ──
MG.register('vitals', {
    title: 'Vitals',
    hint: 'Keep every gauge in the green — tap 1 / 2 / 3 to stabilize',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 380, H = 280;

        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const css = getComputedStyle(document.documentElement);
        const acc = (css.getPropertyValue('--accent') || '#00e0b8').trim();
        const suc = (css.getPropertyValue('--success') || '#39d98a').trim();
        const dng = (css.getPropertyValue('--danger') || '#ff3b5c').trim();

        const labels = ['HR', 'O2', 'BP'];
        const keys = ['Digit1', 'Digit2', 'Digit3'];
        const G = 3;
        const bandH = Math.max(0.16, 0.3 - diff * 0.025);
        const gauges = [];
        for (let i = 0; i < G; i++) { const lo = 0.32 + Math.random() * (0.36 - bandH); gauges.push({ v: 0.5, lo, hi: lo + bandH, vel: 0, drift: 0.05 + diff * 0.02 }); }
        let stab = 0, done = false;
        const stabGain = 0.16;
        let last = performance.now();

        function key(e) { const i = keys.indexOf(e.code); if (i >= 0 && !done) { e.preventDefault(); gauges[i].vel += 0.16; api.sfx('tick'); } }
        document.addEventListener('keydown', key);

        api.setTag('MONITOR');
        api.startTimer(Math.max(20, 34 - diff * 2), () => { if (!done && stab < 1) fail(); });
        function fail() { if (done) return; done = true; document.removeEventListener('keydown', key); api.stopTimer(); api.shake(); setTimeout(() => api.fail(), 200); }
        function win() { if (done) return; done = true; document.removeEventListener('keydown', key); api.stopTimer(); api.setTag('STABLE'); setTimeout(() => api.succeed(), 300); }

        function draw() {
            const now = performance.now(); const dt = Math.min(0.05, (now - last) / 1000); last = now;
            let allIn = true;
            if (!done) {
                gauges.forEach(g => {
                    g.vel += (Math.random() - 0.52) * g.drift * dt * 6;
                    g.vel *= 0.92;
                    g.v = Math.max(0.04, Math.min(0.96, g.v + g.vel * dt * 3));
                    if (g.v < g.lo || g.v > g.hi) allIn = false;
                });
                stab = allIn ? Math.min(1, stab + stabGain * dt) : Math.max(0, stab - stabGain * 0.6 * dt);
                if (stab >= 1) { win(); return; }
            }

            ctx.clearRect(0, 0, W, H);
            const colW = 70, gap = (W - G * colW) / (G + 1), top = 26, bh = H - 96;
            gauges.forEach((g, i) => {
                const x = gap + i * (colW + gap);
                ctx.fillStyle = 'rgba(255,255,255,0.07)'; ctx.fillRect(x, top, colW, bh);
                ctx.fillStyle = 'rgba(57,217,138,0.18)'; ctx.fillRect(x, top + bh * (1 - g.hi), colW, bh * (g.hi - g.lo));
                ctx.strokeStyle = 'rgba(57,217,138,0.5)'; ctx.lineWidth = 1; ctx.strokeRect(x, top + bh * (1 - g.hi), colW, bh * (g.hi - g.lo));
                const inB = g.v >= g.lo && g.v <= g.hi, ny = top + bh * (1 - g.v);
                ctx.fillStyle = inB ? suc : dng; ctx.shadowColor = inB ? suc : dng; ctx.shadowBlur = 10;
                ctx.fillRect(x - 3, ny - 3, colW + 6, 6); ctx.shadowBlur = 0;
                ctx.fillStyle = 'rgba(255,255,255,0.7)'; ctx.font = 'bold 13px monospace'; ctx.textAlign = 'center'; ctx.fillText(labels[i], x + colW / 2, H - 56);
                ctx.fillStyle = acc; ctx.font = '11px monospace'; ctx.fillText('[' + (i + 1) + ']', x + colW / 2, H - 40);
            });

            ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(30, H - 24, W - 60, 10);
            ctx.fillStyle = suc; ctx.fillRect(30, H - 24, (W - 60) * stab, 10);
            ctx.fillStyle = 'rgba(255,255,255,0.5)'; ctx.font = '9px monospace'; ctx.textAlign = 'left'; ctx.fillText('STABILITY ' + Math.round(stab * 100) + '%', 30, H - 27);

            if (!done) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); document.removeEventListener('keydown', key); } };
    }
});

// ── welding.js ──
MG.register('welding', {
    title: 'Welding',
    hint: 'Drag the torch along the seam — steady, not too fast',
    run(api) {
        const diff = Math.max(1, Math.min(5, api.cfg.difficulty || 2));
        const W = 460, H = 240;
        const cvs = document.createElement('canvas');
        cvs.width = W; cvs.height = H;
        cvs.style.cursor = 'crosshair';
        api.board.appendChild(cvs);
        const ctx = cvs.getContext('2d');

        const idealSpeed = 2.0;
        const speedTol = Math.max(1.0, 2.6 - diff * 0.32);
        const seamTol = Math.max(10, 24 - diff * 3);

        // Randomized seam path — different shape every run so it can't be memorized.
        // More nodes + bigger vertical swings at higher difficulty.
        const pts = [];
        const segs = api.randInt(5 + diff, 7 + diff * 2);
        const amp = 30 + diff * 8;
        const midY = H / 2;
        let y = midY + api.rand(-amp, amp);
        for (let i = 0; i <= segs; i++) {
            const x = 40 + (W - 80) * (i / segs);
            if (i === 0) {
                // start somewhere in the safe vertical band
                y = midY + api.rand(-amp * 0.5, amp * 0.5);
            } else {
                // random walk with a pull back toward center so it stays on-canvas
                const step = api.rand(-amp, amp) * (0.5 + diff * 0.12);
                y += step + (midY - y) * 0.25;
                y = Math.max(40, Math.min(H - 40, y));
            }
            pts.push({ x, y });
        }
        let progress = 0, heat = 0, lastX = null, ended = false;
        let holding = false;

        function seamY(x) {
            for (let i = 0; i < pts.length - 1; i++) {
                if (x >= pts[i].x && x <= pts[i + 1].x) {
                    const t = (x - pts[i].x) / (pts[i + 1].x - pts[i].x);
                    return pts[i].y + (pts[i + 1].y - pts[i].y) * t;
                }
            }
            return pts[pts.length - 1].y;
        }
        function rel(e) {
            const b = cvs.getBoundingClientRect();
            return { x: (e.clientX - b.left) * (cvs.width / b.width),
                     y: (e.clientY - b.top) * (cvs.height / b.height) };
        }
        cvs.addEventListener('mousedown', () => holding = true);
        window.addEventListener('mouseup', mUp);
        function mUp() { holding = false; lastX = null; }
        cvs.addEventListener('mousemove', (e) => {
            if (!holding || ended) return;
            const p = rel(e);
            const targetX = pts[0].x + (W - 80) * progress / 100;
            const sy = seamY(p.x);
            if (Math.abs(p.y - sy) > seamTol) { heat += 1.6; }
            if (lastX !== null) {
                const dx = p.x - lastX;
                if (dx > 0) {
                    const spd = dx;
                    if (Math.abs(spd - idealSpeed) > speedTol) heat += 0.9;
                    if (p.x >= targetX - 30) progress = Math.min(100, ((p.x - pts[0].x) / (W - 80)) * 100);
                }
            }
            lastX = p.x;
            heat = Math.max(0, heat - 0.3);
            if (heat > 100) { finish(false); return; }
            if (progress >= 99) { finish(true); return; }
        });

        api.setTag('WELDING');
        api.startTimer(Math.max(12, 24 - diff * 2), () => finish(false));
        function finish(ok) { if (ended) return; ended = true; if (!ok) api.shake(); window.removeEventListener('mouseup', mUp); api.stopTimer(); setTimeout(() => ok ? api.succeed() : api.fail(), 250); }

        function draw() {
            const acc = (getComputedStyle(document.documentElement).getPropertyValue('--accent') || '#00e0b8').trim();
            const suc = (getComputedStyle(document.documentElement).getPropertyValue('--success') || '#39d98a').trim();
            const dng = (getComputedStyle(document.documentElement).getPropertyValue('--danger') || '#ff3b5c').trim();
            ctx.clearRect(0, 0, W, H);

            ctx.strokeStyle = 'rgba(255,255,255,0.12)'; ctx.lineWidth = seamTol * 2; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
            ctx.beginPath(); pts.forEach((p, i) => i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)); ctx.stroke();
            ctx.strokeStyle = 'rgba(255,255,255,0.25)'; ctx.lineWidth = 2; ctx.setLineDash([6, 6]);
            ctx.beginPath(); pts.forEach((p, i) => i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)); ctx.stroke(); ctx.setLineDash([]);

            const weldX = pts[0].x + (W - 80) * progress / 100;
            ctx.strokeStyle = suc; ctx.lineWidth = 5; ctx.shadowColor = suc; ctx.shadowBlur = 10;
            ctx.beginPath();
            for (let x = pts[0].x; x <= weldX; x += 3) { const y = seamY(x); x === pts[0].x ? ctx.moveTo(x, y) : ctx.lineTo(x, y); }
            ctx.stroke(); ctx.shadowBlur = 0;

            ctx.fillStyle = heat > 60 ? dng : acc; ctx.shadowColor = ctx.fillStyle; ctx.shadowBlur = 14;
            ctx.beginPath(); ctx.arc(weldX, seamY(weldX), 8, 0, Math.PI * 2); ctx.fill(); ctx.shadowBlur = 0;

            ctx.fillStyle = 'rgba(255,255,255,0.1)'; ctx.fillRect(40, H - 16, W - 80, 6);
            ctx.fillStyle = heat > 60 ? dng : 'rgba(255,140,0,0.8)';
            ctx.fillRect(40, H - 16, (W - 80) * (heat / 100), 6);
            ctx.fillStyle = 'rgba(255,255,255,0.4)'; ctx.font = '11px monospace'; ctx.textAlign = 'left';
            ctx.fillText('heat', 40, H - 22);
            if (!ended) loop = requestAnimationFrame(draw);
        }
        let loop = requestAnimationFrame(draw);
        return { destroy() { cancelAnimationFrame(loop); window.removeEventListener('mouseup', mUp); } };
    }
});

