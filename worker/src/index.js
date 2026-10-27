const encoder = new TextEncoder();
const ORIGIN_DOWN = [502, 503, 504, 530];

const hex = buffer => Array.from(new Uint8Array(buffer), byte => byte.toString(16).padStart(2, '0')).join('');
const sha256 = async text => hex(await crypto.subtle.digest('SHA-256', encoder.encode(text)));
const hmac = async (key, text) => crypto.subtle.sign('HMAC', await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']), encoder.encode(text));
const base64 = text => atob(text.replace(/-/g, '+').replace(/_/g, '/'));
const bytes = text => Uint8Array.from(base64(text), char => char.charCodeAt(0));
const reply = status => Response.json({ status }, { status: 503, headers: { 'Retry-After': '30' } });

async function matchesWakeKey(value, wakeKey) {
  const [a, b] = await Promise.all([value, wakeKey].map(text => crypto.subtle.digest('SHA-256', encoder.encode(text))));
  return crypto.subtle.timingSafeEqual(a, b);
}

async function validSession(cookie, secret) {
  const parts = /(?:^|;\s*)JWT-SESSION=([^;]*)/.exec(cookie)?.[1].split('.');
  if (parts?.length !== 3) return false;
  const [header, payload, signature] = parts;
  try {
    if (JSON.parse(base64(header)).alg !== 'HS256') return false;
    const { exp } = JSON.parse(base64(payload));
    if (typeof exp !== 'number' || exp <= Date.now() / 1000) return false;
    const key = await crypto.subtle.importKey('raw', bytes(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
    return await crypto.subtle.verify('HMAC', key, bytes(signature), encoder.encode(`${header}.${payload}`));
  } catch {
    return false;
  }
}

async function hasWakeCredential(request, env) {
  const key = request.headers.get('X-Sonar-Wake-Key');
  if (key && await matchesWakeKey(key, env.WAKE_KEY)) return true;
  return validSession(request.headers.get('Cookie'), env.JWT_SECRET);
}

async function setDesiredCapacity(env) {
  const host = `autoscaling.${env.AWS_REGION}.amazonaws.com`;
  const body = new URLSearchParams({ Action: 'SetDesiredCapacity', AutoScalingGroupName: env.ASG_NAME, DesiredCapacity: '1', HonorCooldown: 'false', Version: '2011-01-01' }).toString();
  const date = new Date().toISOString().replace(/[-:]|\.\d{3}/g, '');
  const scope = `${date.slice(0, 8)}/${env.AWS_REGION}/autoscaling/aws4_request`;
  const canonical = `POST\n/\n\nhost:${host}\nx-amz-date:${date}\n\nhost;x-amz-date\n${await sha256(body)}`;
  let key = encoder.encode(`AWS4${env.AWS_SECRET_ACCESS_KEY}`);
  for (const part of scope.split('/')) key = await hmac(key, part);
  const signature = hex(await hmac(key, `AWS4-HMAC-SHA256\n${date}\n${scope}\n${await sha256(canonical)}`));
  return fetch(`https://${host}/`, {
    method: 'POST',
    headers: {
      Authorization: `AWS4-HMAC-SHA256 Credential=${env.AWS_ACCESS_KEY_ID}/${scope}, SignedHeaders=host;x-amz-date, Signature=${signature}`,
      'Content-Type': 'application/x-www-form-urlencoded',
      'X-Amz-Date': date,
    },
    body,
  });
}

export default {
  async fetch(request, env) {
    const response = await fetch(request).catch(() => null);
    if (response && !ORIGIN_DOWN.includes(response.status)) return response;
    if (!await hasWakeCredential(request, env)) return reply('DOWN');
    try {
      const aws = await setDesiredCapacity(env);
      if (aws.ok) return reply('WAKING');
      console.error(`SetDesiredCapacity failed: HTTP ${aws.status}`);
    } catch (error) {
      console.error(`SetDesiredCapacity failed: ${error}`);
    }
    return reply('WAKE_FAILED');
  },
};
