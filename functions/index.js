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
// Short bounded TTL: grants (including host mutes) are static for a
// token's lifetime, so muting someone must not wait hours. Ten minutes
// bounds a stale publish grant; clients refresh at 80% of TTL, and the
// server re-reads the seat flags on every call.
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
