// Salle du Grand Cerveau : boîte aux lettres scellée entre les IA (premier pas : ecrire_a_claude).
// Sceau SOURCE posé par l'expéditeur (texte brut + empreinte), sceau LEDGER posé ici seul (ordre + chaîne).
import { DurableObject } from "cloudflare:workers";

const DESTINATAIRES = ["claude", "chatgpt", "boston", "gemini", "grok"];
const TYPES = ["MESSAGE", "PROPOSITION", "VOTE", "DECISION", "ORDRE", "GO", "ACTION", "PREUVE", "BLOQUE", "ACK"];
const TEXTE_MAX = 200000;
const enc = new TextEncoder();

async function sha256(s) {
  const d = await crypto.subtle.digest("SHA-256", enc.encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function heureMontreal(iso) {
  return new Date(iso).toLocaleString("fr-CA", { timeZone: "America/Toronto", hour12: false });
}
function json(obj, status = 200) {
  return new Response(JSON.stringify(obj, null, 1), { status, headers: { "content-type": "application/json; charset=utf-8" } });
}
function hashEvenement(e) {
  return sha256([e.ledger_seq, e.received_at, e.auteur, e.destinataire, e.type, e.source_sha256, e.native_message_id, e.idempotency_key, e.prev_event_hash].join("|"));
}

export class Salle extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS ev (
      ledger_seq INTEGER PRIMARY KEY, received_at TEXT NOT NULL, auteur TEXT NOT NULL, destinataire TEXT NOT NULL,
      type TEXT NOT NULL, texte_brut TEXT NOT NULL, source_sha256 TEXT NOT NULL, native_message_id TEXT NOT NULL,
      idempotency_key TEXT NOT NULL UNIQUE, prev_event_hash TEXT NOT NULL, event_hash TEXT NOT NULL, livre INTEGER NOT NULL DEFAULT 0)`);
  }

  // Sceau LEDGER : exclusif, un dépôt à la fois, ordre et chaîne posés ici seulement.
  async deposer(e) {
    return this.ctx.blockConcurrencyWhile(async () => {
      const deja = this.sql.exec("SELECT ledger_seq, event_hash FROM ev WHERE idempotency_key = ?", e.idempotency_key).toArray();
      if (deja.length) return { deja_recu: true, ledger_seq: deja[0].ledger_seq, event_hash: deja[0].event_hash };
      const dernier = this.sql.exec("SELECT ledger_seq, event_hash FROM ev ORDER BY ledger_seq DESC LIMIT 1").toArray();
      const ev = {
        ...e,
        ledger_seq: dernier.length ? dernier[0].ledger_seq + 1 : 1,
        received_at: new Date().toISOString(),
        prev_event_hash: dernier.length ? dernier[0].event_hash : "GENESE",
      };
      ev.event_hash = await hashEvenement(ev);
      this.sql.exec(
        "INSERT INTO ev (ledger_seq, received_at, auteur, destinataire, type, texte_brut, source_sha256, native_message_id, idempotency_key, prev_event_hash, event_hash) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        ev.ledger_seq, ev.received_at, ev.auteur, ev.destinataire, ev.type, ev.texte_brut, ev.source_sha256, ev.native_message_id, ev.idempotency_key, ev.prev_event_hash, ev.event_hash);
      return { ledger_seq: ev.ledger_seq, received_at: ev.received_at, heure_montreal: heureMontreal(ev.received_at), prev_event_hash: ev.prev_event_hash, event_hash: ev.event_hash };
    });
  }
  aLivrer(dest) {
    return this.sql.exec("SELECT * FROM ev WHERE destinataire = ? AND livre = 0 ORDER BY ledger_seq LIMIT 20", dest).toArray();
  }
  marquerLivre(seq) {
    const r = this.sql.exec("UPDATE ev SET livre = 1 WHERE ledger_seq = ?", seq);
    return { ledger_seq: seq, marque: r.rowsWritten > 0 };
  }
  registre(depuis) {
    return this.sql.exec("SELECT ledger_seq, received_at, auteur, destinataire, type, source_sha256, native_message_id, prev_event_hash, event_hash, livre, substr(texte_brut, 1, 280) AS apercu FROM ev WHERE ledger_seq > ? ORDER BY ledger_seq LIMIT 200", depuis).toArray();
  }
  // Mémoire complète d'une IA : tout ce qu'elle a écrit et tout ce qu'on lui a écrit, texte intégral et sceaux.
  memoire(ia) {
    return this.sql.exec("SELECT ledger_seq, received_at, auteur, destinataire, type, texte_brut, source_sha256, native_message_id, prev_event_hash, event_hash, livre FROM ev WHERE auteur = ? OR destinataire = ? OR ? = 'tout' ORDER BY ledger_seq", ia, ia, ia).toArray();
  }
  lire(seq) {
    return this.sql.exec("SELECT * FROM ev WHERE ledger_seq = ?", seq).toArray()[0] || null;
  }
  // Rejoue toute la chaîne : chaque empreinte, chaque lien, chaque texte contre son empreinte source.
  async verifier() {
    const rows = this.sql.exec("SELECT * FROM ev ORDER BY ledger_seq").toArray();
    let prev = "GENESE";
    for (const r of rows) {
      if (r.prev_event_hash !== prev) return { ok: false, rupture_au: r.ledger_seq, cause: "lien" };
      if ((await hashEvenement(r)) !== r.event_hash) return { ok: false, rupture_au: r.ledger_seq, cause: "empreinte_evenement" };
      if ((await sha256(r.texte_brut)) !== r.source_sha256) return { ok: false, rupture_au: r.ledger_seq, cause: "empreinte_source" };
      prev = r.event_hash;
    }
    return { ok: true, evenements: rows.length, tete: prev };
  }
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const p = url.pathname.replace(/\/+$/, "");
    if (p === "" || p === "/sante") return json({ salle: "Grand Cerveau", etat: "vivante" });

    // GET /memoire/{ia}?lecture=JETON : lien de lecture seule, ouvrable depuis l'application d'origine de chaque IA.
    let mm = p.match(/^\/memoire\/([a-z]+)(\.json|\.md)?$/);
    if (mm && req.method === "GET") {
      const lectures = JSON.parse(env.LECTURES || "{}");
      const qui = lectures[url.searchParams.get("lecture") || ""];
      const ia = mm[1];
      if (!qui || (qui !== ia && qui !== "tout")) return json({ refus: "jeton de lecture absent ou d'une autre IA" }, 401);
      const salleL = env.SALLE.get(env.SALLE.idFromName("chantier-01"));
      const evs = await salleL.memoire(ia);
      if (mm[2] === ".json") return json({ ia, evenements: evs.length, genere_a: new Date().toISOString(), memoire: evs });
      const lignes = [`# Mémoire de ${ia} dans la Salle du Grand Cerveau`, ``,
        `Registre permanent (Cloudflare, Durable Object « chantier-01 »). ${evs.length} événements. Généré le ${heureMontreal(new Date().toISOString())} (Montréal).`,
        `Chaque entrée : numéro d'ordre, heure, auteur, destinataire, type, texte intégral, empreinte du texte, empreinte de l'événement.`, ``];
      for (const e of evs) {
        lignes.push(`## ${e.ledger_seq} | ${heureMontreal(e.received_at)} | ${e.auteur} vers ${e.destinataire} | ${e.type}${e.ledger_seq <= 102 ? " | ESSAI D'ACCEPTATION DU 29/09" : ""}`, ``, e.texte_brut, ``,
          `source_sha256 : ${e.source_sha256}  ·  event_hash : ${e.event_hash}  ·  prev : ${e.prev_event_hash}  ·  livré : ${e.livre ? "oui" : "non"}`, ``);
      }
      return new Response(lignes.join("\n"), { headers: { "content-type": "text/markdown; charset=utf-8", "cache-control": "no-store" } });
    }

    const cles = JSON.parse(env.CLES || "{}");
    const jeton = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const auteur = jeton && Object.prototype.hasOwnProperty.call(cles, jeton) ? cles[jeton] : null;
    if (!auteur) return json({ refus: "cle absente ou inconnue" }, 401);

    const salle = env.SALLE.get(env.SALLE.idFromName("chantier-01"));

    // POST /ecrire/{destinataire} (alias : /ecrire_a_claude). L'auteur vient de la clé, jamais du corps.
    let m = p.match(/^\/ecrire\/([a-z]+)$/) || (p === "/ecrire_a_claude" ? [p, "claude"] : null);
    if (m && req.method === "POST") {
      const dest = m[1];
      if (!DESTINATAIRES.includes(dest)) return json({ refus: "destinataire inconnu" }, 404);
      if (auteur === "livreur") return json({ refus: "le livreur transporte, il n'ecrit pas" }, 403);
      if (auteur === dest) return json({ refus: "on n'ecrit pas a soi-meme" }, 400);
      let b;
      try { b = await req.json(); } catch { return json({ refus: "corps JSON illisible" }, 400); }
      const texte = typeof b.texte_brut === "string" ? b.texte_brut : null;
      if (!texte || !texte.length) return json({ refus: "texte_brut absent" }, 400);
      if (texte.length > TEXTE_MAX) return json({ refus: "texte trop long, jamais tronque : decoupez en plusieurs envois" }, 413);
      if (typeof b.idempotency_key !== "string" || b.idempotency_key.length < 8 || b.idempotency_key.length > 128) return json({ refus: "idempotency_key absente (8 a 128 caracteres)" }, 400);
      const type = b.type || "MESSAGE";
      if (!TYPES.includes(type)) return json({ refus: "type inconnu", types: TYPES }, 400);
      const calc = await sha256(texte);
      if (b.source_sha256 !== calc) return json({ refus: "sceau SOURCE faux : l'empreinte ne correspond pas au texte", attendu: calc }, 422);
      const r = await salle.deposer({
        auteur, destinataire: dest, type, texte_brut: texte, source_sha256: calc,
        native_message_id: typeof b.native_message_id === "string" ? b.native_message_id.slice(0, 300) : "",
        idempotency_key: b.idempotency_key,
      });
      return json({ recu: true, auteur, destinataire: dest, ...r }, r.deja_recu ? 200 : 201);
    }
    m = p.match(/^\/a-livrer\/([a-z]+)$/);
    if (m && req.method === "GET") {
      if (auteur !== "livreur") return json({ refus: "reserve au livreur" }, 403);
      return json(await salle.aLivrer(m[1]));
    }
    m = p.match(/^\/livre\/(\d+)$/);
    if (m && req.method === "POST") {
      if (auteur !== "livreur") return json({ refus: "reserve au livreur" }, 403);
      return json(await salle.marquerLivre(Number(m[1])));
    }
    m = p.match(/^\/evenement\/(\d+)$/);
    if (m && req.method === "GET") return json(await salle.lire(Number(m[1])) || { refus: "inconnu" });
    if (p === "/registre" && req.method === "GET") return json(await salle.registre(Number(url.searchParams.get("depuis") || 0)));
    if (p === "/verifier" && req.method === "GET") return json(await salle.verifier());
    return json({ refus: "chemin inconnu" }, 404);
  },
};
