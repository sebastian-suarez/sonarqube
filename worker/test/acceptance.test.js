import assert from 'node:assert/strict';
import { createHash, createHmac, timingSafeEqual, webcrypto } from 'node:crypto';
import { existsSync } from 'node:fs';
import { test } from 'node:test';

const BASE = 'https://sonar.sebastiansuarez.dev';
const NOW = new Date('2026-10-26T12:00:00Z');
const env = Object.freeze({
  ASG_NAME: 'sonarqube', AWS_REGION: 'us-east-1',
  AWS_ACCESS_KEY_ID: 'AKIDEXAMPLE',
  AWS_SECRET_ACCESS_KEY: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
  WAKE_KEY: 'acceptance-wake-key-0123456789abcdef',
  JWT_SECRET: Buffer.from('0123456789abcdef0123456789abcdef').toString('base64'),
});
const sha256 = value => createHash('sha256').update(value).digest('hex');
const hmac = (key, value) => createHmac('sha256', key).update(value).digest();
const encode = value => encodeURIComponent(value).replace(/[!'()*]/g, c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);

function signature(request, body, secret) {
  const auth = request.headers.get('authorization');
  assert.ok(auth, 'AWS request must be signed');
  const match = /^AWS4-HMAC-SHA256 Credential=([^/]+)\/(\d{8})\/([^/]+)\/([^/]+)\/aws4_request,\s*SignedHeaders=([^,]+),\s*Signature=([a-f0-9]{64})$/.exec(auth);
  assert.ok(match, `invalid SigV4 authorization: ${auth}`);
  const [, key, day, region, service, signed, actual] = match;
  const names = signed.split(';');
  assert.deepEqual(names, [...new Set(names)].sort(), 'SignedHeaders must be sorted and unique');
  assert.ok(names.includes('host'));
  const dateHeader = request.headers.get('x-amz-date') ?? request.headers.get('date');
  assert.ok(dateHeader, 'AWS request needs a signing date');
  const url = new URL(request.url);
  const query = [...url.searchParams].map(([k, v]) => [encode(k), encode(v)])
    .sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0)
    .map(([k, v]) => `${k}=${v}`).join('&');
  const headers = names.map(name => {
    const value = name === 'host' ? url.host : request.headers.get(name);
    assert.notEqual(value, null, `missing signed header ${name}`);
    return `${name}:${value.trim().replace(/\s+/g, ' ')}\n`;
  }).join('');
  const path = url.pathname.split('/').map(part => encode(decodeURIComponent(part))).join('/');
  const canonical = [request.method, path || '/', query, headers, signed, sha256(body)].join('\n');
  const scope = `${day}/${region}/${service}/aws4_request`;
  const date = /^\d{8}T\d{6}Z$/.test(dateHeader) ? dateHeader : new Date(dateHeader).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
  assert.ok(date.startsWith(day));
  const stringToSign = ['AWS4-HMAC-SHA256', date, scope, sha256(canonical)].join('\n');
  const signingKey = hmac(hmac(hmac(hmac(`AWS4${secret}`, day), region), service), 'aws4_request');
  return { key, region, service, day, actual, expected: hmac(signingKey, stringToSign).toString('hex') };
}

test('B7 checker: published AKIDEXAMPLE IAM ListUsers vector', () => {
  // AWS IAM SigV4 example: https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
  const expected = '5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7';
  const request = new Request('https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08', {
    headers: {
      'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
      'x-amz-date': '20150830T123600Z',
      authorization: `AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=${expected}`,
    },
  });
  assert.equal(signature(request, '', env.AWS_SECRET_ACCESS_KEY).expected, expected);
});

function jwt(payload = { exp: NOW.getTime() / 1000 + 600 }, header = { alg: 'HS256', typ: 'JWT' }, key = Buffer.from(env.JWT_SECRET, 'base64')) {
  const parts = [header, payload].map(value => Buffer.from(JSON.stringify(value)).toString('base64url'));
  const input = parts.join('.');
  return `${input}.${createHmac('sha256', key).update(input).digest('base64url')}`;
}

async function exercise(t, { status = 530, originThrows = false, awsStatus = 200, awsThrows = false, request = new Request(BASE), originResponse } = {}) {
  const moduleURL = new URL('../src/index.js', import.meta.url);
  assert.ok(existsSync(moduleURL), 'implementation missing: worker/src/index.js');
  const expectedRequest = { url: request.url, method: request.method, headers: [...request.headers], body: await request.clone().text() };
  t.mock.timers.enable({ apis: ['Date'], now: NOW.getTime() });
  if (!crypto.subtle.timingSafeEqual) {
    Object.defineProperty(crypto.subtle, 'timingSafeEqual', { configurable: true, value: (a, b) => {
      const left = Buffer.from(a), right = Buffer.from(b);
      return left.length === right.length && timingSafeEqual(left, right);
    } });
    t.after(() => { delete crypto.subtle.timingSafeEqual; });
  }
  assert.ok(webcrypto.subtle);
  const worker = (await import(moduleURL.href)).default;
  assert.equal(typeof worker?.fetch, 'function');
  const calls = { origin: [], aws: [], errors: [] };
  t.mock.method(console, 'error', (...args) => calls.errors.push(args));
  t.mock.method(globalThis, 'fetch', async (input, init) => {
    const forwarded = new Request(input, init);
    const body = await forwarded.clone().text();
    const host = new URL(forwarded.url).host;
    if (host === 'autoscaling.us-east-1.amazonaws.com') {
      calls.aws.push({ request: forwarded, body });
      if (awsThrows) throw new Error('simulated AWS failure');
      return new Response('<SetDesiredCapacityResponse/>', { status: awsStatus });
    }
    assert.equal(host, new URL(BASE).host, 'unexpected outbound host');
    calls.origin.push({ request: forwarded, body });
    if (originThrows) throw new TypeError('simulated tunnel failure');
    return originResponse?.clone() ?? new Response('origin unavailable', { status });
  });
  const pending = [];
  const response = await worker.fetch(request, env, { waitUntil: p => pending.push(p), passThroughOnException() {} });
  await Promise.all(pending);
  assert.ok(response instanceof Response);
  assert.ok(calls.origin.length <= 1, 'B6: at most one origin fetch');
  for (const forwarded of calls.origin) {
    assert.equal(forwarded.request.url, expectedRequest.url);
    assert.equal(forwarded.request.method, expectedRequest.method);
    assert.deepEqual([...forwarded.request.headers], expectedRequest.headers);
    assert.equal(forwarded.body, expectedRequest.body);
  }
  return { ...calls, response };
}

async function answer(result, status) {
  assert.equal(result.response.status, 503);
  assert.equal(result.response.headers.get('retry-after'), '30');
  assert.deepEqual(await result.response.json(), { status });
}
function wakeRequest(headers = {}) {
  return new Request(`${BASE}/api/system/status`, { headers: { 'X-Sonar-Wake-Key': env.WAKE_KEY, ...headers } });
}
function awsRequest(result) {
  assert.equal(result.aws.length, 1);
  const { request, body } = result.aws[0];
  assert.equal(request.method, 'POST');
  assert.equal(request.url, 'https://autoscaling.us-east-1.amazonaws.com/');
  assert.match(request.headers.get('content-type'), /^application\/x-www-form-urlencoded(?:;|$)/);
  const form = new URLSearchParams(body);
  assert.equal([...form].length, 5);
  assert.deepEqual(Object.fromEntries(form), {
    Action: 'SetDesiredCapacity', AutoScalingGroupName: 'sonarqube', DesiredCapacity: '1', HonorCooldown: 'false', Version: '2011-01-01',
  });
  const signed = signature(request, body, env.AWS_SECRET_ACCESS_KEY);
  assert.equal(signed.key, env.AWS_ACCESS_KEY_ID);
  assert.equal(signed.region, 'us-east-1');
  assert.equal(signed.service, 'autoscaling');
  assert.equal(signed.day, '20261026');
  assert.equal(signed.expected, signed.actual);
}

for (const method of ['GET', 'POST']) for (const authenticated of [false, true]) {
  test(`B1 B6: ${method} authenticated=${authenticated} preserves the request and successful origin response`, async t => {
    const headers = { authorization: 'Bearer pass-through', cookie: 'session=opaque', 'x-custom': 'keep-me', ...(authenticated ? { 'x-sonar-wake-key': env.WAKE_KEY } : {}) };
    const request = new Request(`${BASE}/api/example?q=a%20b`, { method, headers, ...(method === 'POST' ? { body: 'unaltered\nbody' } : {}) });
    const originalHeaders = [...request.headers];
    const result = await exercise(t, { request, originResponse: new Response('response\nbytes', { status: 200, headers: { 'x-origin': 'kept', 'content-type': 'text/plain', 'set-cookie': 'JWT-SESSION=opaque' } }) });
    assert.equal(result.origin.length, 1);
    assert.equal(result.origin[0].request.url, request.url);
    assert.equal(result.origin[0].request.method, method);
    assert.deepEqual([...result.origin[0].request.headers], originalHeaders);
    assert.equal(result.origin[0].body, method === 'POST' ? 'unaltered\nbody' : '');
    assert.equal(result.response.status, 200);
    assert.deepEqual([...result.response.headers], [...new Headers({ 'x-origin': 'kept', 'content-type': 'text/plain', 'set-cookie': 'JWT-SESSION=opaque' })]);
    assert.equal(await result.response.text(), 'response\nbytes');
    assert.equal(result.aws.length, 0);
  });
}
for (const down of [502, 503, 504, 530, 'throw']) {
  test(`B2 B6 B7: ${down} wakes once with independently verified SigV4`, async t => {
    const result = await exercise(t, { status: down === 'throw' ? 530 : down, originThrows: down === 'throw', request: wakeRequest() });
    assert.equal(result.origin.length, 1);
    awsRequest(result);
    await answer(result, 'WAKING');
  });
  test(`B3 B6: ${down} without a credential does not wake`, async t => {
    const result = await exercise(t, { status: down === 'throw' ? 530 : down, originThrows: down === 'throw' });
    assert.equal(result.aws.length, 0);
    await answer(result, 'DOWN');
  });
}
for (const status of [401, 403, 404, 429, 500]) {
  test(`B6: origin status ${status} is passed through with one unchanged request`, async t => {
    const request = wakeRequest({ authorization: 'Bearer untouched', cookie: 'a=b' });
    const result = await exercise(t, { status, request });
    assert.equal(result.origin.length, 1);
    assert.deepEqual([...result.origin[0].request.headers], [...request.headers]);
    assert.equal(result.aws.length, 0);
    assert.equal(result.response.status, status);
    assert.equal(await result.response.text(), 'origin unavailable');
  });
}
for (const failure of [403, 500, 'throw']) {
  test(`B4: AWS ${failure} logs a redacted failure`, async t => {
    const cookie = jwt();
    const result = await exercise(t, { request: wakeRequest({ cookie: `JWT-SESSION=${cookie}` }), awsStatus: failure === 'throw' ? 500 : failure, awsThrows: failure === 'throw' });
    assert.equal(result.aws.length, 1);
    await answer(result, 'WAKE_FAILED');
    assert.ok(result.errors.length > 0);
    const logs = result.errors.map(args => args.map(arg => arg instanceof Error ? `${arg.message}\n${arg.stack}` : typeof arg === 'string' ? arg : JSON.stringify(arg)).join(' ')).join('\n');
    for (const secret of [env.AWS_ACCESS_KEY_ID, env.AWS_SECRET_ACCESS_KEY, env.WAKE_KEY, env.JWT_SECRET, Buffer.from(env.JWT_SECRET, 'base64').toString(), cookie]) assert.ok(!logs.includes(secret), 'credentials must not appear in logs');
  });
}
const validJWT = jwt();
const parts = validJWT.split('.');
const rejected = [
  ['bearer', { authorization: 'Bearer valid-looking-token' }],
  ['basic', { authorization: 'Basic YWRtaW46YWRtaW4=' }],
  ['wrong wake key', { 'x-sonar-wake-key': 'wrong-key' }],
  ['empty wake key', { 'x-sonar-wake-key': '' }],
  ['truncated wake key', { 'x-sonar-wake-key': env.WAKE_KEY.slice(0, -1) }],
  ['bad signature', { cookie: `JWT-SESSION=${jwt(undefined, undefined, Buffer.from('wrong-secret'))}` }],
  ['modified payload', { cookie: `JWT-SESSION=${parts[0]}.${Buffer.from(JSON.stringify({ exp: NOW.getTime() / 1000 + 99999 })).toString('base64url')}.${parts[2]}` }],
  ['HS384', { cookie: `JWT-SESSION=${jwt(undefined, { alg: 'HS384' })}` }],
  ['none', { cookie: `JWT-SESSION=${jwt(undefined, { alg: 'none' })}` }],
  ['unsigned none', { cookie: `JWT-SESSION=${jwt(undefined, { alg: 'none' }).split('.').slice(0, 2).join('.')}.` }],
  ['no exp', { cookie: `JWT-SESSION=${jwt({ sub: 'owner' })}` }],
  ['expired', { cookie: `JWT-SESSION=${jwt({ exp: NOW.getTime() / 1000 - 1 })}` }],
  ['exp at now', { cookie: `JWT-SESSION=${jwt({ exp: NOW.getTime() / 1000 })}` }],
  ['not JWT', { cookie: 'JWT-SESSION=not-a-jwt' }],
];
for (const [name, headers] of rejected) {
  test(`B5: rejects ${name}`, async t => {
    const result = await exercise(t, { request: new Request(BASE, { headers }) });
    assert.equal(result.aws.length, 0);
    await answer(result, 'DOWN');
  });
}
test('B8: an independently signed HS256 session cookie wakes', async t => {
  const result = await exercise(t, { request: new Request(BASE, { headers: { cookie: `other=one; JWT-SESSION=${validJWT}; tail=two` } }) });
  awsRequest(result);
  await answer(result, 'WAKING');
});
