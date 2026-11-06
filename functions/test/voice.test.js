// Unit tests for the voice token + moderation endpoints.
// Run: cd functions && npm install && npm test
//
// Mocks: Firestore is stubbed by replacing getFirestore before loading
// index.js; the LiveKit RoomServiceClient is stubbed through
// __setRoomServiceFactoryForTests. Token contents are verified for real
// with TokenVerifier (same crypto LiveKit uses).
process.env.LIVEKIT_API_SECRET = 'test-secret-test-secret-test-secret';

const test = require('node:test');
const assert = require('node:assert/strict');
const firestore = require('firebase-admin/firestore');
const { TokenVerifier } = require('livekit-server-sdk');

let snap;
let updates;
let updateImpl = async (data) => updates.push(data);
firestore.getFirestore = () => ({
  collection: () => ({
    doc: () => ({
      get: async () => snap,
      update: async (data) => updateImpl(data),
    }),
  }),
});

const mod = require('../index.js');
const mint = mod.mintVoiceToken.run || mod.mintVoiceToken;
const moderate = mod.moderateVoiceParticipant.run || mod.moderateVoiceParticipant;

const SEATED = () => ({
  exists: true,
  data: () => ({
    hostId: 'host',
    players: [
      { id: 'host', name: 'ه', micMuted: false },
      { id: 'u1', name: 'علي', micMuted: false },
      { id: 'u2', name: 'ب', micMuted: true },
    ],
    board: {},
  }),
});

async function expectCode(fn, code) {
  await assert.rejects(fn, (e) => e.code === code);
}

test('mint: unauthenticated rejected', async () => {
  snap = SEATED();
  await expectCode(mint({ data: { tableId: 't1' } }), 'unauthenticated');
});

test('mint: non-seat rejected', async () => {
  snap = { exists: true, data: () => ({ players: [{ id: 'x' }] }) };
  await expectCode(
    mint({ auth: { uid: 'u9' }, data: { tableId: 't1' } }),
    'permission-denied',
  );
});

test('mint: missing table rejected', async () => {
  snap = { exists: false, data: () => undefined };
  await expectCode(
    mint({ auth: { uid: 'u1' }, data: { tableId: 'nope' } }),
    'not-found',
  );
});

test('mint: seated player gets a room-bound token', async () => {
  snap = SEATED();
  const res = await mint({ auth: { uid: 'u1' }, data: { tableId: 't1' } });
  assert.equal(res.canPublish, true);
  assert.ok(res.expiresInSeconds > 0);
  const v = new TokenVerifier('APIKw29rPMTjQSy', process.env.LIVEKIT_API_SECRET);
  const decoded = await v.verify(res.token);
  assert.equal(decoded.video.room, 't1');
  assert.equal(decoded.sub, 'u1');
  assert.equal(decoded.video.canPublish, true);
  assert.equal(decoded.video.canSubscribe, true);
});

test('mint: host-muted seat gets listen-only, flag and legacy list', async () => {
  snap = SEATED();
  const res = await moderateReady();
  async function moderateReady() {
    return mint({ auth: { uid: 'u2' }, data: { tableId: 't1' } });
  }
  assert.equal(res.canPublish, false);
  const v = new TokenVerifier('APIKw29rPMTjQSy', process.env.LIVEKIT_API_SECRET);
  const decoded = await v.verify(res.token);
  assert.equal(decoded.video.canPublish, false);

  snap = {
    exists: true,
    data: () => ({ players: [{ id: 'u1' }], board: { mutedMics: ['u1'] } }),
  };
  const res2 = await mint({ auth: { uid: 'u1' }, data: { tableId: 't1' } });
  assert.equal(res2.canPublish, false);
});

function stubService(calls) {
  mod.__setRoomServiceFactoryForTests(() => ({
    updateParticipant: async (room, identity, options) =>
      calls.push({ op: 'update', room, identity, options }),
    removeParticipant: async (room, identity) =>
      calls.push({ op: 'remove', room, identity }),
  }));
}

test('moderate: non-host rejected', async () => {
  snap = SEATED();
  const calls = [];
  stubService(calls);
  await expectCode(
    moderate({
      auth: { uid: 'u1' },
      data: { tableId: 't1', targetId: 'u2', action: 'mute' },
    }),
    'permission-denied',
  );
  assert.equal(calls.length, 0);
});

test('moderate: host mute updates room grant and seat flags', async () => {
  snap = SEATED();
  const calls = [];
  updates = [];
  stubService(calls);
  const res = await moderate({
    auth: { uid: 'host' },
    data: { tableId: 't1', targetId: 'u1', action: 'mute' },
  });
  assert.equal(res.ok, true);
  assert.deepEqual(calls, [
    {
      op: 'update',
      room: 't1',
      identity: 'u1',
      options: {
        // Full grant set every call: listener role preserved on mute.
        permission: {
          canPublish: false,
          canSubscribe: true,
          canPublishData: true,
        },
      },
    },
  ]);
  const players = updates[0].players;
  assert.equal(players.find((p) => p.id === 'u1').micMuted, true);
  assert.deepEqual(updates[0].board.mutedMics, ['u1', 'u2']);
});

test('moderate: unmute and remove map to the right server calls', async () => {
  snap = SEATED();
  const calls = [];
  updates = [];
  stubService(calls);
  await moderate({
    auth: { uid: 'host' },
    data: { tableId: 't1', targetId: 'u2', action: 'unmute' },
  });
  assert.deepEqual(calls[0].options.permission, {
    canPublish: true,
    canSubscribe: true,
    canPublishData: true,
  });
  assert.deepEqual(updates[0].board.mutedMics, []);
  await moderate({
    auth: { uid: 'host' },
    data: { tableId: 't1', targetId: 'u1', action: 'remove' },
  });
  assert.deepEqual(calls[1], { op: 'remove', room: 't1', identity: 'u1' });
  assert.equal(updates.length, 1, 'remove leaves seats untouched');
});

test('moderate: LiveKit failure leaves table state untouched', async () => {
  snap = SEATED();
  updates = [];
  mod.__setRoomServiceFactoryForTests(() => ({
    updateParticipant: async () => {
      throw new Error('livekit down');
    },
    removeParticipant: async () => {},
  }));
  await assert.rejects(
    moderate({
      auth: { uid: 'host' },
      data: { tableId: 't1', targetId: 'u1', action: 'mute' },
    }),
    /livekit down/,
  );
  assert.equal(updates.length, 0, 'no Firestore write after LiveKit failure');
});

test('moderate: Firestore failure rolls the room grant back', async () => {
  snap = SEATED();
  const calls = [];
  mod.__setRoomServiceFactoryForTests(() => ({
    updateParticipant: async (room, identity, options) =>
      calls.push({ op: 'update', room, identity, options }),
    removeParticipant: async () => {},
  }));
  // Force the Firestore write to fail (the module caches db at load).
  snap = SEATED();
  updateImpl = async () => {
    throw new Error('firestore down');
  };
  await assert.rejects(
    moderate({
      auth: { uid: 'host' },
      data: { tableId: 't1', targetId: 'u1', action: 'mute' },
    }),
    (e) =>
      e.code === 'internal' &&
      /restored to its previous value/.test(e.message) &&
      !/room unchanged/.test(e.message),
  );
  assert.equal(calls.length, 2, 'mute then rollback');
  assert.equal(calls[0].options.permission.canPublish, false);
  // u1 was unmuted before, so the rollback restores publish rights.
  assert.equal(calls[1].options.permission.canPublish, true);
  updateImpl = async (data) => updates.push(data);
});

test('moderate: rollback failure surfaces a partial-failure error', async () => {
  const calls = [];
  mod.__setRoomServiceFactoryForTests(() => ({
    updateParticipant: async (room, identity, options) => {
      calls.push({ room, identity, options });
      if (calls.length === 2) {
        throw new Error('livekit rollback down');
      }
    },
    removeParticipant: async () => {},
  }));
  snap = SEATED();
  updateImpl = async () => {
    throw new Error('firestore down');
  };
  await assert.rejects(
    moderate({
      auth: { uid: 'host' },
      data: { tableId: 't1', targetId: 'u1', action: 'mute' },
    }),
    (e) =>
      e.code === 'internal' &&
      /rollback also failed/.test(e.message) &&
      /may disagree/.test(e.message) &&
      !/room unchanged/.test(e.message),
  );
  assert.equal(calls.length, 2, 'mute then failed rollback');
  assert.equal(updates.length, 0, 'table never written');
  updateImpl = async (data) => updates.push(data);
});

test('moderate: self-target and unknown action rejected', async () => {
  snap = SEATED();
  stubService([]);
  await expectCode(
    moderate({
      auth: { uid: 'host' },
      data: { tableId: 't1', targetId: 'host', action: 'mute' },
    }),
    'invalid-argument',
  );
  await expectCode(
    moderate({
      auth: { uid: 'host' },
      data: { tableId: 't1', targetId: 'u1', action: 'explode' },
    }),
    'invalid-argument',
  );
});
