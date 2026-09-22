/**
 * Vercel serverless entry point (optional deployment).
 *
 * The local prototype runs server/server.mjs. This file exposes the same
 * decision contract on Vercel when you want the iOS app to work without a
 * laptop process running. The key lives in the Vercel project environment.
 *
 * Configure: vercel env add TYPESAFE_API_KEY
 */

import { classify, applyPolicy, DECISION_MODES, CONFIDENCE_POLICY } from "../server/lib/jev.mjs";

const MAX_BODY_BYTES = 64 * 1024;

function bodyOf(req) {
  if (req.body && typeof req.body === "object") return req.body;
  if (typeof req.body === "string") {
    try {
      return JSON.parse(req.body);
    } catch {
      return null;
    }
  }
  return null;
}

export default async function handler(req, res) {
  res.setHeader("cache-control", "no-store");

  if (req.method === "GET") {
    return res.status(200).json({
      ok: true,
      service: "mira-decision-proxy",
      keyConfigured: Boolean(process.env.TYPESAFE_API_KEY),
      modelRequested: process.env.TYPESAFE_MODEL || "jev-1.13.0",
      defaultDecisionMode: process.env.TYPESAFE_API_KEY ? DECISION_MODES.JEV_LIVE : DECISION_MODES.RULES_ONLY,
      confidencePolicy: CONFIDENCE_POLICY,
      financialMode: "SIMULATED",
    });
  }

  if (req.method !== "POST") {
    return res.status(405).json({ error: "method_not_allowed" });
  }

  const raw = JSON.stringify(req.body ?? "").length;
  if (raw > MAX_BODY_BYTES) {
    return res.status(413).json({ error: "payload_too_large" });
  }

  const payload = bodyOf(req);
  if (!payload || typeof payload.state !== "string" || payload.state.trim().length === 0) {
    return res.status(422).json({ error: "state_required" });
  }

  const result = await classify({
    state: payload.state,
    sessionId: payload.sessionId ?? "unknown",
  });

  return res.status(200).json({
    ...applyPolicy(result),
    financialMode: "SIMULATED",
    notice:
      "A routing label is not permission to execute the corresponding operation. Deterministic code owns amounts, eligibility, limits and consent.",
  });
}
