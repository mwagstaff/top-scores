// Traditional football: truncated icosahedron projected onto a sphere.
import fs from "node:fs";
import path from "node:path";

const out = process.argv[2];
const phi = (1 + Math.sqrt(5)) / 2;
const C = 512;

const norm = (v) => { const l = Math.hypot(...v); return v.map((x) => x / l); };
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const evenPerms = (v) => [v, [v[1], v[2], v[0]], [v[2], v[0], v[1]]];
function signed(base) {
  const res = [];
  for (const sx of [1, -1]) for (const sy of [1, -1]) for (const sz of [1, -1]) {
    const v = [base[0] * sx, base[1] * sy, base[2] * sz];
    if (!res.some((r) => r.every((x, i) => Math.abs(x - v[i]) < 1e-9))) res.push(v);
  }
  return res;
}
const expand = (bases) => {
  const res = [];
  for (const b of bases) for (const p of evenPerms(b)) for (const v of signed(p))
    if (!res.some((r) => r.every((x, i) => Math.abs(x - v[i]) < 1e-9))) res.push(v);
  return res;
};

const verts = expand([[0, 1, 3 * phi], [1, 2 + phi, 2 * phi], [phi, 2, 2 * phi + 1]]).map(norm);
const pentCentres = expand([[0, 1, phi]]).map(norm);
const hexCentres = expand([[1, 1, 1], [0, phi, 1 / phi]]).map(norm);

function face(centre, n) {
  const vs = verts.map((v) => [dot(v, centre), v]).sort((a, b) => b[0] - a[0]).slice(0, n).map((x) => x[1]);
  const u = norm(cross(centre, Math.abs(centre[0]) < 0.9 ? [1, 0, 0] : [0, 1, 0]));
  const w = cross(centre, u);
  return vs.sort((a, b) => Math.atan2(dot(a, w), dot(a, u)) - Math.atan2(dot(b, w), dot(b, u)));
}
const faces = [
  ...pentCentres.map((c) => ({ c, vs: face(c, 5), pent: true })),
  ...hexCentres.map((c) => ({ c, vs: face(c, 6), pent: false })),
];

// Rotate so one pentagon faces the viewer, then tilt slightly for depth.
function rotTo(a) {
  // rotation taking unit vector a to +z
  const z = [0, 0, 1], k = cross(a, z), s = Math.hypot(...k), c = dot(a, z);
  if (s < 1e-9) return (v) => v;
  const kn = k.map((x) => x / s);
  return (v) => {
    const kv = cross(kn, v), kd = dot(kn, v);
    return v.map((x, i) => x * c + kv[i] * s + kn[i] * kd * (1 - c));
  };
}
const rx = (t) => (v) => [v[0], v[1] * Math.cos(t) - v[2] * Math.sin(t), v[1] * Math.sin(t) + v[2] * Math.cos(t)];
const ry = (t) => (v) => [v[0] * Math.cos(t) + v[2] * Math.sin(t), v[1], -v[0] * Math.sin(t) + v[2] * Math.cos(t)];
const rz = (t) => (v) => [v[0] * Math.cos(t) - v[1] * Math.sin(t), v[0] * Math.sin(t) + v[1] * Math.cos(t), v[2]];

function build({ tiltX, tiltY, spin }) {
  const r0 = rotTo(pentCentres[0]);
  // spin so the front pentagon points up (screen y is down, so -y)
  const p0 = face(pentCentres[0], 5).map(r0);
  const a = Math.atan2(p0[0][1], p0[0][0]);
  const T = (v) => ry(tiltY)(rx(tiltX)(rz(-Math.PI / 2 - a + spin)(r0(v))));
  return faces.map((f) => ({ ...f, c: T(f.c), vs: f.vs.map(T) }));
}

// Great-circle sampled outline, projected orthographically; back points pushed to the horizon.
function outline(vs, R, steps = 14) {
  const pts = [];
  for (let i = 0; i < vs.length; i++) {
    const a = vs[i], b = vs[(i + 1) % vs.length];
    for (let s = 0; s < steps; s++) {
      const t = s / steps;
      let p = norm(a.map((x, j) => x * (1 - t) + b[j] * t));
      if (p[2] < 0) { const l = Math.hypot(p[0], p[1]); p = [p[0] / l, p[1] / l, 0]; }
      pts.push([C + R * p[0], C - R * p[1]]);
    }
  }
  return pts.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
}

const light = norm([-0.45, 0.6, 0.65]);
const mix = (a, b, t) => "#" + [0, 2, 4].map((i) => Math.round(parseInt(a.slice(i + 1, i + 3), 16) * (1 - t) + parseInt(b.slice(i + 1, i + 3), 16) * t).toString(16).padStart(2, "0")).join("");

function icon(small) {
  const R = small ? 474 : 372;
  const fs_ = build(small ? { tiltX: 0.12, tiltY: -0.1, spin: 0 } : { tiltX: 0.22, tiltY: -0.16, spin: 0.08 });
  const vis = fs_.filter((f) => f.c[2] > -0.35).sort((a, b) => a.c[2] - b.c[2]);
  const seam = small ? 26 : 9;
  const panels = vis.map((f) => {
    const d = Math.max(0, dot(f.c, light));
    if (f.pent) {
      return `<polygon points="${outline(f.vs, R)}" fill="${mix("#08142C", "#1E3F7A", d)}" stroke="#0A1630" stroke-width="${seam}" stroke-linejoin="round"/>`;
    }
    return `<polygon points="${outline(f.vs, R)}" fill="${small ? mix("#E3ECF8", "#FFFFFF", d) : mix("#9DB3D3", "#FFFFFF", d)}" stroke="#0A1630" stroke-opacity="${small ? 1 : 0.85}" stroke-width="${seam}" stroke-linejoin="round"/>`;
  }).join("\n    ");
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#0E1D3D"/><stop offset="1" stop-color="#030814"/>
    </linearGradient>
    <radialGradient id="halo" cx="0.5" cy="0.56" r="0.5">
      <stop offset="0" stop-color="#2F7BFF" stop-opacity="0.45"/><stop offset="1" stop-color="#2F7BFF" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="shade" cx="0.36" cy="0.3" r="0.85">
      <stop offset="0.45" stop-color="#000814" stop-opacity="0"/><stop offset="1" stop-color="#000814" stop-opacity="0.5"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.85"/><stop offset="0.5" stop-color="#9CC8FF" stop-opacity="0.1"/><stop offset="1" stop-color="#3D8BFF" stop-opacity="0.95"/>
    </linearGradient>
    <linearGradient id="spec" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.9"/><stop offset="0.28" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <mask id="cres"><circle cx="${C}" cy="${C}" r="${R * 0.93}" fill="#fff"/><circle cx="${C}" cy="${C + R * 0.14}" r="${R * 0.95}" fill="#000"/></mask>
    <clipPath id="clip"><circle cx="${C}" cy="${C}" r="${R}"/></clipPath>
  </defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
  ${small ? "" : `<circle cx="${C}" cy="${C + 30}" r="480" fill="url(#halo)"/>`}
  <circle cx="${C}" cy="${C}" r="${R}" fill="#0A1630"/>
  <g clip-path="url(#clip)">
    ${panels}
    ${small ? "" : `<circle cx="${C}" cy="${C}" r="${R}" fill="url(#shade)"/>
    <circle cx="${C}" cy="${C}" r="${R}" fill="url(#spec)" mask="url(#cres)"/>`}
  </g>
  <circle cx="${C}" cy="${C}" r="${R - (small ? 10 : 6)}" fill="none" stroke="${small ? "#0A1630" : "url(#rim)"}" stroke-width="${small ? 20 : 12}"/>
</svg>`;
}

fs.writeFileSync(path.join(out, "ball.svg"), icon(false));
fs.writeFileSync(path.join(out, "ball-small.svg"), icon(true));
