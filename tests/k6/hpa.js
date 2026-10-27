import http from 'k6/http';
import { check } from 'k6';

const API = __ENV.API_URL || 'http://api.dev.localtest.me';
const AUTH = __ENV.AUTH_URL || 'http://auth.dev.localtest.me';
const PEAK = parseInt(__ENV.PEAK_VUS || '150');
const HOLD = __ENV.HOLD || '4m';

export const options = {
  stages: [
    { duration: '30s', target: Math.ceil(PEAK / 4) },
    { duration: '30s', target: PEAK },
    { duration: HOLD, target: PEAK },
    { duration: '30s', target: 0 },
  ],
  thresholds: { http_req_failed: ['rate<0.5'] },
};

http.setResponseCallback(http.expectedStatuses(200, 429));

let token = null;
let issuedAt = 0;

function login() {
  const res = http.post(`${AUTH}/token`, {
    grant_type: 'client_credentials',
    client_id: __ENV.CLIENT_ID,
    client_secret: __ENV.CLIENT_SECRET,
  });
  check(res, { 'login 200': (r) => r.status === 200 });
  token = res.status === 200 ? res.json('access_token') : null;
  issuedAt = Date.now();
}

export default function () {
  if (!token || Date.now() - issuedAt > 45000) login();
  const res = http.get(`${API}/hazard-events`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  check(res, { 'status 200 atau 429': (r) => r.status === 200 || r.status === 429 });
}
