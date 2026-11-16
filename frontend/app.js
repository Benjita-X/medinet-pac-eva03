// Frontend del módulo PAC. Mismo origen que la API (el ALB enruta /patients al backend),
// así no se necesita CORS. Todo dato se inserta con textContent: nunca innerHTML (anti-XSS).
'use strict';

const $ = (id) => document.getElementById(id);
const PAGE_SIZE = 10;
let token = sessionStorage.getItem('pac_token') || '';
let page = 1;
let lastQuery = null;

// ---------- RUN chileno: normalización y Módulo 11 ----------
function cleanRun(value) {
  return value.replace(/[^0-9kK]/g, '').toUpperCase();
}
function computeDv(body) {
  let sum = 0;
  let factor = 2;
  for (let i = body.length - 1; i >= 0; i--) {
    sum += Number(body[i]) * factor;
    factor = factor === 7 ? 2 : factor + 1;
  }
  const rest = 11 - (sum % 11);
  return rest === 11 ? '0' : rest === 10 ? 'K' : String(rest);
}
function formatRun(raw) {
  const c = cleanRun(raw);
  if (c.length < 2) return c;
  const body = c.slice(0, -1);
  const dv = c.slice(-1);
  return body.replace(/\B(?=(\d{3})+(?!\d))/g, '.') + '-' + dv;
}
function runStatus(raw) {
  const c = cleanRun(raw);
  if (!c) return { ok: false, msg: 'Escribe el RUN.' };
  const body = c.slice(0, -1);
  const dv = c.slice(-1);
  if (!/^\d{7,8}$/.test(body)) return { ok: false, msg: 'El RUN debe tener 7 u 8 dígitos más el dígito verificador.' };
  const expected = computeDv(body);
  if (dv !== expected) return { ok: false, msg: 'Dígito verificador incorrecto: para ' + body + ' debería ser ' + expected + '.' };
  return { ok: true, msg: 'RUN válido.', normalized: body + '-' + dv };
}

// ---------- sesión ----------
function decodeSubject(jwt) {
  try {
    const part = jwt.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const data = JSON.parse(atob(part));
    return (data.sub || 'usuario') + ' · ' + (data.roles || []).join(', ');
  } catch (e) {
    return null;
  }
}
function showSession() {
  const label = token ? decodeSubject(token) : null;
  $('who').textContent = label ? 'Sesión: ' + label : 'Sin sesión';
  $('who').className = 'who' + (label ? ' on' : '');
}

async function api(path, options) {
  const headers = { 'Accept': 'application/json' };
  if (token) headers['Authorization'] = 'Bearer ' + token;
  if (options && options.body) headers['Content-Type'] = 'application/json';
  const res = await fetch(path, Object.assign({ headers, credentials: 'omit', cache: 'no-store' }, options || {}));
  let body = null;
  try { body = await res.json(); } catch (e) { body = null; }
  return { status: res.status, body };
}
function errorText(status, body) {
  if (status === 401) return 'No autorizado: falta el token o no es válido (401).';
  if (status === 403) return 'Tu rol no permite esta acción (403).';
  if (status === 409) return 'Ese RUN ya está registrado (409).';
  if (status === 422) {
    const first = body && Array.isArray(body.detail) && body.detail[0];
    const field = first && first.loc ? first.loc[first.loc.length - 1] : 'los datos';
    return 'Revisa ' + field + ': el servidor rechazó el valor (422).';
  }
  if (status === 503) return 'La base de datos no está disponible; intenta en un momento (503).';
  return 'Error inesperado (' + status + ').';
}

// ---------- registro ----------
function setOut(el, text, kind) {
  el.textContent = text;
  el.className = 'out ' + (kind || '');
}
function onRunInput() {
  const input = $('run');
  const formatted = formatRun(input.value);
  if (formatted !== input.value) input.value = formatted;
  const st = runStatus(input.value);
  $('runMsg').textContent = st.msg;
  $('runMsg').className = 'msg ' + (input.value ? (st.ok ? 'ok' : 'bad') : '');
  input.setAttribute('aria-invalid', String(!st.ok && !!input.value));
}

async function onRegister(e) {
  e.preventDefault();
  const out = $('regOut');
  const st = runStatus($('run').value);
  if (!st.ok) { setOut(out, st.msg, 'bad'); $('run').focus(); return; }
  const data = { run: st.normalized };
  for (const name of ['nombres', 'apellido_paterno', 'apellido_materno', 'fecha_nacimiento', 'prevision', 'email', 'telefono', 'direccion']) {
    const v = $(name).value.trim();
    if (v) data[name] = v;
  }
  for (const name of ['nombres', 'apellido_paterno', 'fecha_nacimiento', 'prevision']) {
    if (!data[name]) { setOut(out, 'Completa el campo obligatorio: ' + $(name).labels[0].textContent + '.', 'bad'); $(name).focus(); return; }
  }
  $('regBtn').disabled = true;
  setOut(out, 'Registrando…', '');
  try {
    const r = await api('/patients', { method: 'POST', body: JSON.stringify(data) });
    if (r.status === 201) {
      setOut(out, 'Paciente registrado con ID ' + r.body.id + ' (RUN ' + r.body.run + ').', 'ok');
      $('regForm').reset();
      onRunInput();
    } else {
      setOut(out, errorText(r.status, r.body), 'bad');
    }
  } catch (err) {
    setOut(out, 'No se pudo conectar con el servidor.', 'bad');
  } finally {
    $('regBtn').disabled = false;
  }
}

// ---------- búsqueda paginada ----------
function renderRows(items) {
  const tbody = $('results');
  tbody.replaceChildren();
  if (!items.length) {
    const tr = document.createElement('tr');
    const td = document.createElement('td');
    td.colSpan = 4; td.className = 'empty'; td.textContent = 'Sin resultados.';
    tr.appendChild(td); tbody.appendChild(tr);
    return;
  }
  for (const p of items) {
    const tr = document.createElement('tr');
    const cells = [
      formatRun(p.run),
      [p.nombres, p.apellido_paterno, p.apellido_materno].filter(Boolean).join(' '),
      p.fecha_nacimiento,
      p.prevision,
    ];
    for (const text of cells) {
      const td = document.createElement('td');
      td.textContent = text;
      tr.appendChild(td);
    }
    tbody.appendChild(tr);
  }
}
async function search(newPage) {
  if (!lastQuery) return;
  const params = new URLSearchParams(lastQuery);
  params.set('page', String(newPage));
  params.set('page_size', String(PAGE_SIZE));
  const r = await api('/patients?' + params.toString());
  if (r.status !== 200) {
    renderRows([]);
    $('results').firstChild.firstChild.textContent = errorText(r.status, r.body);
    $('prev').disabled = true; $('next').disabled = true;
    return;
  }
  page = newPage;
  renderRows(r.body.items);
  const pages = Math.max(1, Math.ceil(r.body.total / PAGE_SIZE));
  $('pageInfo').textContent = 'Página ' + page + ' de ' + pages + ' · ' + r.body.total + ' pacientes';
  $('prev').disabled = page <= 1;
  $('next').disabled = page >= pages;
}
function onSearch(e) {
  e.preventDefault();
  const q = {};
  const pat = $('s_paterno').value.trim();
  const run = cleanRun($('s_run').value);
  const prev = $('s_prev').value;
  if (pat) q.apellido_paterno = pat;
  if (run) q.run = run.slice(0, -1) + '-' + run.slice(-1);
  if (prev) q.prevision = prev;
  lastQuery = q;
  search(1);
}

document.addEventListener('DOMContentLoaded', () => {
  $('token').value = token;
  showSession();
  $('tokenForm').addEventListener('submit', (e) => {
    e.preventDefault();
    token = $('token').value.trim();
    try { sessionStorage.setItem('pac_token', token); } catch (err) { /* modo privado */ }
    showSession();
  });
  $('run').addEventListener('input', onRunInput);
  $('s_run').addEventListener('input', () => { $('s_run').value = formatRun($('s_run').value); });
  $('regForm').addEventListener('submit', onRegister);
  $('searchForm').addEventListener('submit', onSearch);
  $('prev').addEventListener('click', () => search(page - 1));
  $('next').addEventListener('click', () => search(page + 1));
});
