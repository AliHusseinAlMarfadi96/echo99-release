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
