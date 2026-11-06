const { initializeApp } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const { getDatabase } = require("firebase-admin/database");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const logger = require("firebase-functions/logger");

initializeApp({
  databaseURL: ["https://", "echo99-9e73b-default-rtdb", ".", "firebaseio", ".", "com"].join(""),
});

const db = getFirestore();
const rtdb = getDatabase();
const GHOST_TABLE_MS = 60 * 1000;
const DISCONNECT_BOT_MS = 45 * 1000;
const LEGACY_GHOST_MS = 6 * 60 * 60 * 1000;

function isStale(data, now) {
  const beat = data.heartbeatAt;
  if (typeof beat === "number" && Number.isFinite(beat)) {
    return now - beat > GHOST_TABLE_MS;
  }
  const created = data.createdAt;
  if (created instanceof Timestamp) {
    return now - created.toMillis() > LEGACY_GHOST_MS;
  }
  return false;
}

async function removePresence(tableId, hostId) {
  try {
    await rtdb.ref(`tables/${tableId}`).remove();
    if (hostId) {
      const pointer = rtdb.ref(`hosting/${hostId}`);
      const snap = await pointer.get();
      if (snap.exists() && snap.val() === tableId) {
        await pointer.remove();
      }
    }
  } catch (error) {
    logger.error("Failed to clean up RTDB presence during sweep", {
      tableId,
      message: String(error),
    });
  }
}

exports.sweepGhostTables = onSchedule(
  {
    schedule: "every 15 minutes",
    timeZone: "Asia/Riyadh",
    region: "us-central1",
    timeoutSeconds: 540,
    memory: "256MiB",
  },
  async () => {
    const now = Date.now();
    const snapshot = await db.collection("tables").get();
    let removed = 0;

    for (const doc of snapshot.docs) {
      const data = doc.data();
      const players = data.players || [];
      const humanPlayers = players.filter((p) => !p.isBot);

      if (
        humanPlayers.length === 0 ||
        (data.status === "waiting" && data.hostId && !players.some((p) => p.id === data.hostId))
      ) {
        await db.runTransaction(async (tx) => {
          tx.delete(doc.ref);
        });
        await db.recursiveDelete(doc.ref);
        await removePresence(doc.id, data.hostId);
        removed += 1;
        continue;
      }

      if (data.status === "playing") {
        let updated = false;
        const updatedPlayers = players.map((p) => {
          if (!p.isBot && p.lastSeenAt && now - p.lastSeenAt > DISCONNECT_BOT_MS) {
            updated = true;
            return {
              ...p,
              isBot: true,
              name: `Bot ${p.name || ""}`.trim(),
            };
          }
          return p;
        });
        if (updated) {
          await doc.ref.update({ players: updatedPlayers });
        }
      }

      if (!isStale(data, now)) continue;

      const result = await db.runTransaction(async (tx) => {
        const latest = await tx.get(doc.ref);
        if (!latest.exists || !isStale(latest.data() || {}, Date.now())) {
          return { deleted: false, hostId: "" };
        }
        const hostId =
          typeof latest.get("hostId") === "string" ? latest.get("hostId") : "";
        tx.delete(doc.ref);
        return { deleted: true, hostId };
      });
      if (!result.deleted) continue;

      await db.recursiveDelete(doc.ref);
      await removePresence(doc.id, result.hostId);
      removed += 1;
    }

    logger.info("Ghost-table sweep completed", {
      scanned: snapshot.size,
      removed,
    });
  }
);

// ---------------------------------------------------------------------------
// LiveKit voice token endpoint (NOT DEPLOYED YET).
//
// Why: the app currently mints room JWTs on the client from a
// LIVEKIT_API_SECRET baked in at build time, so every shipped APK carries
// the secret. Here the secret never leaves the server.
//
// Deploy (owner action): firebase deploy --only functions
//   then: firebase functions:secrets:set LIVEKIT_API_SECRET
// Client change (separate slice): replace mintConfiguredToken() in
// lib/livekit_token.dart with a call here and re-call before expiry.
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { AccessToken } = require("livekit-server-sdk");

const livekitApiSecret = defineSecret("LIVEKIT_API_SECRET");
// Public coordinates, safe in source (same values the client already ships).
const LIVEKIT_API_KEY = "APIKw29rPMTjQSy";
// Token expiry limits the INITIAL connection only (LiveKit docs), never an
// active session: muting a connected participant is enforced by
// moderateVoiceParticipant via the server API, not by token expiry. A short
// TTL still bounds rejoin with stale grants; clients refresh at 80%.
const TOKEN_TTL_SECONDS = 10 * 60;

exports.mintVoiceToken = onCall(
  { secrets: [livekitApiSecret] },
  async (request) => {
    // 1. The caller must be signed in with Firebase Auth.
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError("unauthenticated", "Sign in first.");
    }
    const uid = request.auth.uid;
    const tableId = String(request.data.tableId || "");
    if (!tableId) {
      throw new HttpsError("invalid-argument", "tableId is required.");
    }

    // 2. The caller must hold a seat at this exact table; the LiveKit room
    //    name is bound to the table id, so a token for one table never
    //    opens another table's room.
    const snap = await db.collection("tables").doc(tableId).get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Table not found.");
    }
    const state = snap.data();
    const seats = Array.isArray(state.players) ? state.players : [];
    const seat = seats.find((s) => s && s.id === uid);
    if (!seat) {
      throw new HttpsError(
        "permission-denied",
        "Only seated players can join the voice room.",
      );
    }

    // 3. Mic grants follow the table state: a host-muted seat (current flag
    //    or the legacy board list older clients still write) receives a
    //    listen-only token.
    const legacyMuted =
      state.board && Array.isArray(state.board.mutedMics)
        ? state.board.mutedMics
        : [];
    const canPublish = !(seat.micMuted === true || legacyMuted.includes(uid));

    const displayName = String(seat.name || uid).slice(0, 128);
    const token = new AccessToken(LIVEKIT_API_KEY, livekitApiSecret.value(), {
      identity: uid,
      name: displayName,
      ttl: TOKEN_TTL_SECONDS,
    });
    token.addGrant({
      room: tableId,
      roomJoin: true,
      canPublish,
      canSubscribe: true,
      canPublishData: true,
    });

    return {
      token: await token.toJwt(),
      expiresInSeconds: TOKEN_TTL_SECONDS,
      canPublish,
    };
  },
);

// ---------------------------------------------------------------------------
// Host voice moderation (NOT DEPLOYED YET). Token expiry does NOT affect an
// active LiveKit session (docs.livekit.io/frontends/reference/tokens-grants),
// so host mutes are enforced here through the server API: updateParticipant
// flips canPublish on the live participant; removeParticipant disconnects
// (and on LiveKit Cloud revokes) them. The seat flags are updated in the same
// call so the table state and the room state never diverge.
const { RoomServiceClient } = require("livekit-server-sdk");

const LIVEKIT_HTTP_URL = "https://echo99-0o54hspu.livekit.cloud";

// Factory indirection so tests can stub the LiveKit server call.
let roomServiceFactory = (host, key, secret) =>
  new RoomServiceClient(host, key, secret);
exports.__setRoomServiceFactoryForTests = (factory) => {
  roomServiceFactory =
    factory ||
    ((host, key, secret) => new RoomServiceClient(host, key, secret));
};

exports.moderateVoiceParticipant = onCall(
  { secrets: [livekitApiSecret] },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError("unauthenticated", "Sign in first.");
    }
    const uid = request.auth.uid;
    const tableId = String(request.data.tableId || "");
    const targetId = String(request.data.targetId || "");
    const action = String(request.data.action || "");
    if (!tableId || !targetId || !action) {
      throw new HttpsError(
        "invalid-argument",
        "tableId, targetId and action are required.",
      );
    }
    if (!["mute", "unmute", "remove"].includes(action)) {
      throw new HttpsError("invalid-argument", "Unknown action.");
    }

    const ref = db.collection("tables").doc(tableId);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Table not found.");
    }
    const state = snap.data();
    // Host-only, exactly like hostSeatControl in table_repository.dart.
    if (state.hostId !== uid) {
      throw new HttpsError("permission-denied", "Only the host moderates.");
    }
    if (targetId === uid) {
      throw new HttpsError("invalid-argument", "Cannot target yourself.");
    }
    const seats = Array.isArray(state.players) ? state.players : [];
    const seat = seats.find((s) => s && s.id === targetId);
    if (!seat) {
      throw new HttpsError("not-found", "Target is not seated.");
    }

    const svc = roomServiceFactory(
      LIVEKIT_HTTP_URL,
      LIVEKIT_API_KEY,
      livekitApiSecret.value(),
    );
    // LiveKit applies permission objects atomically ("all desired
    // permissions would need to be set"), so every call carries the full
    // grant set and a mute never drops the listener role.
    const grant = (canPublish) => ({
      canPublish,
      canSubscribe: true,
      canPublishData: true,
    });
    const legacyMuted =
      state.board && Array.isArray(state.board.mutedMics)
        ? state.board.mutedMics
        : [];
    const previousMuted =
      seat.micMuted === true || legacyMuted.includes(targetId);
    if (action === "remove") {
      await svc.removeParticipant(tableId, targetId);
      return { ok: true };
    }

    // Ordering: LiveKit first, Firestore second. If the LiveKit call fails
    // the table state is untouched. If the Firestore write fails after the
    // room changed, attempt to roll the room grant back to the previous
    // value and report the outcome honestly.
    //
    // Limits (deliberately unsupported, fail closed on ambiguity):
    // - There is NO transaction across LiveKit and Firestore; this function
    //   cannot make the two systems atomic.
    // - Concurrent moderation of the same target (two host actions, or a
    //   seat change racing a mute) is last-writer-wins per system and can
    //   diverge if either system fails mid-sequence.
    // - The rollback restores the grant observed BEFORE this call, which a
    //   racing action may already have changed.
    // Reconciliation in every ambiguous case: the host retries the action;
    // each call writes the full grant set, so a retry converges both
    // systems to the requested state.
    await svc.updateParticipant(tableId, targetId, {
      permission: grant(action === "unmute"),
    });
    const players = seats.map((s) =>
      s && s.id === targetId ? { ...s, micMuted: action === "mute" } : s,
    );
    const board = { ...(state.board || {}) };
    board.mutedMics = players.filter((s) => s && s.micMuted).map((s) => s.id);
    try {
      await ref.update({ players, board });
    } catch (e) {
      try {
        await svc.updateParticipant(tableId, targetId, {
          permission: grant(!previousMuted),
        });
      } catch (rollbackError) {
        // Partial failure: the room grant may show the new state while the
        // table still shows the old one. Say so; never claim the room is
        // unchanged or the systems agree.
        throw new HttpsError(
          "internal",
          "Table write failed and room rollback also failed; the room " +
            "grant and the table state may disagree. Retry the action to reconcile.",
        );
      }
      // Rollback call succeeded: the room grant was changed and then
      // restored to its previous value. It did not stay "unchanged".
      throw new HttpsError(
        "internal",
        "Table write failed; room grant restored to its previous value.",
      );
    }
    return { ok: true };
  },
);
