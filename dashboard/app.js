import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/+esm';
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './config.js';

const configured = !SUPABASE_URL.includes('YOUR-PROJECT') && !SUPABASE_PUBLISHABLE_KEY.startsWith('YOUR-');
const sb = configured ? createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY) : null;

const STATES = ['DRAFT', 'LOBBY', 'PREPARING', 'ACTIVE', 'PAUSED', 'FINISHED', 'TERMINATED'];
const LABEL = { DRAFT: 'Upcoming', LOBBY: 'Lobby open', PREPARING: 'Starting', ACTIVE: 'Live', PAUSED: 'Paused', FINISHED: 'Finished', TERMINATED: 'Stopped' };
const TINT = { LOBBY: 'ok', PREPARING: 'warn', ACTIVE: 'neon', PAUSED: 'warn', TERMINATED: 'crit' };
const DEFAULTS = {
  hiders: 1, method: 'random', headStart: true, headStartMin: 3, startMode: 'manual', durationMin: 20,
  reveal: 'proximity', revealEveryMin: 2, threshold: 15, accuracyMax: 20, seekersSeeSeekers: false,
  hidersSeeSeekers: true, capacity: 50, minPlayers: 4, distRef: 'origin', hiderRank: 'separate',
};

const S = { session: null, profile: null, games: [], sel: null, roster: [], audit: [], email: '', codeSent: false, showNew: false, channel: null };
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toast.h);
  toast.h = setTimeout(() => (t.hidden = true), 4200);
}

async function rpc(fn, args) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) { toast(error.message); throw error; }
  return data;
}

// ---------- data ----------
async function loadProfile() {
  const { data, error } = await sb.from('profiles').select('*').eq('id', S.session.user.id).single();
  if (error) toast(error.message);
  S.profile = data;
}

async function loadGames() {
  const { data, error } = await sb.from('games').select('*').eq('organizer_id', S.session.user.id)
    .order('created_at', { ascending: false });
  if (error) return toast(error.message);
  S.games = data;
  if (S.sel) S.sel = S.games.find((g) => g.id === S.sel.id) || null;
}

async function loadSelected() {
  if (!S.sel) { S.roster = []; S.audit = []; return; }
  const [r, a] = await Promise.all([
    sb.from('game_players').select('user_id, role, status, ready, volunteer, joined_at, profile:profiles(display_name)')
      .eq('game_id', S.sel.id).order('joined_at'),
    sb.from('audit_log').select('action, detail, at').eq('game_id', S.sel.id).order('at', { ascending: false }).limit(50),
  ]);
  if (r.error) toast(r.error.message); else S.roster = r.data;
  if (a.error) toast(a.error.message); else S.audit = a.data;
}

async function select(id) {
  S.sel = S.games.find((g) => g.id === id) || null;
  S.showNew = false;
  await loadSelected();
  listen();
  render();
}

function listen() {
  if (S.channel) sb.removeChannel(S.channel);
  S.channel = null;
  if (!S.sel) return;
  const gid = S.sel.id;
  S.channel = sb.channel(`org-${gid}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'games', filter: `id=eq.${gid}` }, async () => { await loadGames(); await loadSelected(); render(); })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'game_players', filter: `game_id=eq.${gid}` }, async () => { await loadSelected(); render(); })
    .subscribe();
}

// ---------- views ----------
function viewUnconfigured() {
  return `<div class="center"><div class="mega">GAME<br>NITE</div><div class="panel"><h3>Not connected yet</h3>
  <p class="muted">Add the Supabase project URL and publishable key to <code>dashboard/config.js</code>.</p></div></div>`;
}

function viewSignIn() {
  return `<div class="center"><div class="mega">GAME<br>NITE</div>
  <div class="panel glow"><h2>Organizer sign-in</h2>
  ${S.codeSent ? `
    <p class="muted">Enter the 6-digit code sent to ${esc(S.email)}.</p>
    <form data-form="verify" class="list"><input type="text" name="code" inputmode="numeric" autocomplete="one-time-code" placeholder="123456" required>
    <button class="btn cta">Sign in</button></form>
    <p><button class="btn sm" data-act="resetEmail">Use a different email</button></p>` : `
    <form data-form="email" class="list"><input type="email" name="email" autocomplete="email" placeholder="you@example.com" required value="${esc(S.email)}">
    <button class="btn cta">Email me a code</button></form>`}
  </div></div>`;
}

function viewNotOrganizer() {
  return `${header()}<div class="panel"><h3>You're not an organizer</h3>
  <p class="muted">This dashboard is for Game Nite organizers. Ask an admin to mark your account as an organizer, then reload.</p></div>`;
}

function header() {
  return `<header><span class="logo">GAME NITE</span><span class="tag">Organizer dashboard</span>
  <span class="who">${esc(S.profile?.display_name || S.session.user.email || '')}<button class="btn sm" data-act="signOut">Sign out</button></span></header>`;
}

function statePill(st) { return `<span class="pill ${TINT[st] || ''}">${LABEL[st]}</span>`; }

function viewMain() {
  return `${header()}<div class="grid">
  <aside class="list"><div class="row"><h2 class="sp" style="margin:0">Your games</h2><button class="btn sm cta" data-act="newGame">New game</button></div>
    ${S.games.length ? S.games.map((g) => `<button class="gitem" data-act="select" data-id="${g.id}" aria-current="${S.sel?.id === g.id}">
      <span class="row"><b class="sp">${esc(g.title)}</b>${statePill(g.status)}</span>
      <small>${g.join_code} · ${g.starts_at ? new Date(g.starts_at).toLocaleString([], { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : 'Instant'}</small></button>`).join('')
      : '<p class="muted">No games yet. Create one to get a join code.</p>'}
  </aside>
  <main>${S.showNew ? viewForm() : S.sel ? viewGame(S.sel) : '<div class="panel muted">Pick a game, or create a new one.</div>'}</main></div>`;
}

function cfgFields(c, locked) {
  const d = locked ? 'disabled' : '';
  const num = (k, label, min, max) => `<label class="f">${label}<input type="number" name="${k}" min="${min}" max="${max}" value="${c[k]}" ${d}></label>`;
  const sel = (k, label, opts) => `<label class="f">${label}<select name="${k}" ${d}>${opts.map(([v, t]) => `<option value="${v}" ${String(c[k]) === v ? 'selected' : ''}>${t}</option>`).join('')}</select></label>`;
  const chk = (k, label) => `<label class="f check"><input type="checkbox" name="${k}" ${c[k] ? 'checked' : ''} ${d}>${label}</label>`;
  return `<div class="form">
    ${num('hiders', 'Initial hiders', 1, 5)}
    ${sel('method', 'Hider selection', [['random', 'Random'], ['manual', 'Organizer picks'], ['volunteer', 'Volunteers']])}
    ${chk('headStart', 'Head start')}
    ${num('headStartMin', 'Head start (min)', 1, 15)}
    ${num('durationMin', 'Game length (min)', 5, 120)}
    ${sel('reveal', 'Clue mode', [['proximity', 'Distance clues'], ['continuous', 'Shaded area (live)'], ['periodic', 'Shaded area (periodic)']])}
    ${num('revealEveryMin', 'Periodic reveal every (min)', 1, 10)}
    ${num('threshold', 'Find radius (m)', 5, 50)}
    ${num('accuracyMax', 'Worst GPS accuracy accepted (m)', 5, 50)}
    ${num('capacity', 'Capacity', 4, 50)}
    ${num('minPlayers', 'Minimum players', 2, 50)}
    ${chk('seekersSeeSeekers', 'Seekers see other seekers')}
    ${chk('hidersSeeSeekers', 'Hiding group sees seekers')}
    ${sel('distRef', 'Unfinished seekers measured to (pilot setting)', [['origin', 'Original hiding spot'], ['nearest', 'Nearest hiding-group member']])}
    ${sel('hiderRank', 'Initial hiders ranked (pilot setting)', [['separate', 'Listed separately'], ['first', 'Shared 1st place']])}
  </div>`;
}

function readCfg(form) {
  const f = new FormData(form);
  const out = {};
  for (const [k, v] of Object.entries(DEFAULTS)) {
    if (typeof v === 'boolean') out[k] = form.elements[k]?.checked ?? v;
    else if (typeof v === 'number') { if (f.has(k)) out[k] = Number(f.get(k)); }
    else if (f.has(k)) out[k] = String(f.get(k));
  }
  return out;
}

function viewForm() {
  return `<div class="panel glow"><h3>New game</h3><p class="muted">Sardines · players join with the code or QR you get after saving.</p>
  <form data-form="create" class="list">
    <div class="form">
      <label class="f">Title<input type="text" name="title" required minlength="3" maxlength="60" value="Friday Night Sardines"></label>
      <label class="f">Type<select name="kind"><option value="scheduled">Scheduled</option><option value="instant">Instant</option></select></label>
      <label class="f">Starts<input type="datetime-local" name="starts_at"></label>
      <label class="f">Location<input type="text" name="location" placeholder="Downtown Provo" maxlength="80"></label>
    </div>
    <h2 style="margin-top:12px">Rules</h2>
    ${cfgFields(DEFAULTS, false)}
    <div class="row" style="margin-top:8px"><button class="btn cta">Create game</button><button type="button" class="btn" data-act="cancelNew">Cancel</button></div>
  </form></div>`;
}

function qr(text) {
  if (!window.qrcode) return '';
  const q = window.qrcode(0, 'M');
  q.addData(text);
  q.make();
  return q.createSvgTag({ cellSize: 4, margin: 0, scalable: true });
}

function viewGame(g) {
  const joined = S.roster.filter((p) => p.status === 'joined');
  const ready = joined.filter((p) => p.ready).length;
  const locked = !!g.config_locked_at;
  const cfg = { ...DEFAULTS, ...g.config };
  const canStart = g.status === 'LOBBY' && joined.length >= cfg.minPlayers;
  return `<div class="panel glow">
    <div class="row"><div class="sp"><h3>${esc(g.title)}</h3>
      <div class="muted">${g.starts_at ? new Date(g.starts_at).toLocaleString() : 'Instant game'}${g.location_name ? ' · ' + esc(g.location_name) : ''}</div></div>
      <div class="row"><div><div class="tag">Join code</div><div class="code">${g.join_code}</div></div>
      <div class="qr" aria-label="QR code for ${g.join_code}">${qr('gamenite://join/' + g.join_code)}</div></div></div>
    <div class="states">${STATES.map((s) => `<span class="${g.status === s ? 'on' + (s === 'TERMINATED' ? ' crit' : '') : ''}">${s}</span>`).join('')}</div>
    <div class="row">
      ${g.status === 'DRAFT' ? '<button class="btn cta" data-act="openLobby">Open lobby</button>' : ''}
      ${g.status === 'LOBBY' ? `<button class="btn cta" data-act="start" ${canStart ? '' : 'disabled'}>Start game</button>
        <span class="muted">${canStart ? `${joined.length} players, ${ready} ready` : `Need ${cfg.minPlayers} players (have ${joined.length})`}</span>` : ''}
      ${['PREPARING', 'ACTIVE', 'PAUSED'].includes(g.status) ? '<span class="muted">Live game controls (timeline, pause, finds) arrive in Stage 2.</span>' : ''}
      <span class="sp"></span>
      ${!['FINISHED', 'TERMINATED'].includes(g.status) ? '<button class="btn danger" data-act="terminate">Terminate</button>' : ''}
    </div>
    ${g.end_reason ? `<p class="muted">Ended: ${esc(g.end_reason)}</p>` : ''}
  </div>
  <div class="cols">
    <section class="panel"><h2>Players · ${joined.length}/${cfg.capacity}</h2>
      ${S.roster.length ? `<table><thead><tr><th>Name</th><th>Ready</th><th>Role</th><th></th></tr></thead><tbody>
      ${S.roster.map((p) => `<tr style="${p.status !== 'joined' ? 'opacity:.5' : ''}">
        <td>${esc(p.profile?.display_name || 'Player')}${p.volunteer ? ' <span class="pill neon">Volunteer</span>' : ''}${p.status !== 'joined' ? ` <span class="pill">${p.status}</span>` : ''}</td>
        <td><span class="dot ${p.ready ? 'on' : ''}" aria-label="${p.ready ? 'Ready' : 'Not ready'}"></span></td>
        <td>${['DRAFT', 'LOBBY'].includes(g.status) && cfg.method === 'manual' && p.status === 'joined'
          ? `<button class="btn sm" data-act="toggleHider" data-uid="${p.user_id}" data-role="${p.role}">${p.role === 'hider' ? 'Hider ✓' : 'Make hider'}</button>`
          : `<span class="pill ${p.role === 'hider' ? 'neon' : ''}">${p.role}</span>`}</td>
        <td>${p.status === 'joined' && !['FINISHED', 'TERMINATED'].includes(g.status) ? `<button class="btn sm danger" data-act="remove" data-uid="${p.user_id}">Remove</button>` : ''}</td>
      </tr>`).join('')}</tbody></table>` : '<p class="muted">Nobody has joined yet. Share the code or QR.</p>'}
    </section>
    <section class="panel"><h2>Rules ${locked ? '<span class="pill warn">Locked v' + g.config_version + '</span>' : '<span class="pill">v' + g.config_version + '</span>'}</h2>
      <form data-form="config">${cfgFields(cfg, locked)}
      ${locked ? '<p class="muted">Rules locked when the game started.</p>' : '<div class="row" style="margin-top:10px"><button class="btn">Save rules</button></div>'}</form>
    </section>
    <section class="panel"><h2>Audit log</h2><ul class="log">
      ${S.audit.map((a) => `<li><b>${esc(a.action.replace(/_/g, ' '))}</b> <span class="muted">${new Date(a.at).toLocaleTimeString()}</span>
        ${a.detail?.reason ? `<div class="muted">${esc(a.detail.reason)}</div>` : ''}</li>`).join('') || '<li class="muted">No actions yet.</li>'}
    </ul></section>
  </div>`;
}

function render() {
  const el = $('#app');
  if (!configured) el.innerHTML = viewUnconfigured();
  else if (!S.session) el.innerHTML = viewSignIn();
  else if (!S.profile?.is_organizer) el.innerHTML = viewNotOrganizer();
  else el.innerHTML = viewMain();
}

// ---------- actions ----------
const ACTS = {
  signOut: async () => { await sb.auth.signOut(); },
  resetEmail: () => { S.codeSent = false; render(); },
  newGame: () => { S.showNew = true; S.sel = null; listen(); render(); },
  cancelNew: () => { S.showNew = false; render(); },
  select: (el) => select(el.dataset.id),
  openLobby: async () => { await rpc('open_lobby', { gid: S.sel.id }); toast('Lobby is open.'); },
  start: async () => {
    if (!confirm('Start the game? Rules lock and roles are assigned now.')) return;
    await rpc('start_game', { gid: S.sel.id });
    toast('Game started. Roles assigned.');
  },
  terminate: async () => {
    const reason = prompt('Why are you terminating this game? (required, logged)');
    if (!reason?.trim()) return;
    await rpc('terminate_game', { gid: S.sel.id, reason: reason.trim() });
  },
  remove: async (el) => {
    const reason = prompt('Reason for removing this player? (required, logged)');
    if (!reason?.trim()) return;
    await rpc('remove_player', { gid: S.sel.id, uid: el.dataset.uid, reason: reason.trim() });
  },
  toggleHider: async (el) => {
    await rpc('set_player_role', { gid: S.sel.id, uid: el.dataset.uid, p_role: el.dataset.role === 'hider' ? 'pending' : 'hider' });
    await loadSelected(); render();
  },
};

const FORMS = {
  email: async (form) => {
    S.email = new FormData(form).get('email').trim();
    const { error } = await sb.auth.signInWithOtp({ email: S.email });
    if (error) return toast(error.message);
    S.codeSent = true; render();
    document.querySelector('input[name=code]')?.focus();
  },
  verify: async (form) => {
    const token = new FormData(form).get('code').trim();
    const { error } = await sb.auth.verifyOtp({ email: S.email, token, type: 'email' });
    if (error) toast(error.message);
  },
  create: async (form) => {
    const f = new FormData(form);
    const startsAt = f.get('starts_at');
    const gid = await rpc('create_game', {
      p_title: f.get('title').trim(), p_kind: f.get('kind'),
      p_starts_at: startsAt ? new Date(startsAt).toISOString() : null,
      p_location: f.get('location').trim(), p_config: readCfg(form),
    });
    await loadGames();
    await select(gid);
    toast('Game created.');
  },
  config: async (form) => {
    await rpc('update_game_config', { gid: S.sel.id, p_config: readCfg(form) });
    toast('Rules saved.');
  },
};

document.addEventListener('click', async (e) => {
  const el = e.target.closest('[data-act]');
  if (!el || !ACTS[el.dataset.act]) return;
  e.preventDefault();
  try { await ACTS[el.dataset.act](el); } catch (err) { console.error(err); }
});

document.addEventListener('submit', async (e) => {
  const form = e.target.closest('[data-form]');
  if (!form || !FORMS[form.dataset.form]) return;
  e.preventDefault();
  const btn = form.querySelector('button:not([type=button])');
  if (btn) btn.disabled = true;
  try { await FORMS[form.dataset.form](form); } catch (err) { console.error(err); }
  if (btn && document.body.contains(btn)) btn.disabled = false;
});

// ---------- boot ----------
async function onSession(session) {
  S.session = session;
  if (session) {
    await loadProfile();
    if (S.profile?.is_organizer) {
      await loadGames();
      sb.channel('org-games').on('postgres_changes', { event: '*', schema: 'public', table: 'games' }, async () => { await loadGames(); render(); }).subscribe();
    }
  }
  render();
}

if (sb) {
  const { data } = await sb.auth.getSession();
  await onSession(data.session);
  sb.auth.onAuthStateChange((event, session) => {
    if (event === 'SIGNED_IN' && session?.user.id !== S.session?.user.id) onSession(session);
    if (event === 'SIGNED_OUT') { S.games = []; S.sel = null; onSession(null); }
  });
} else {
  render();
}
