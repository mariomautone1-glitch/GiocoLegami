// legami-posta: servizio Cloudflare Worker che spedisce le email degli account (conferma, nuova password, ...)
// per CineLegami e GiocoLegami, ognuno dalla sua casella Aruba.
// Supabase lo chiama tramite «Send Email Hook» e indica da quale sito arriva la richiesta (redirect_to).
//
// Variabili da impostare nel Worker (Settings > Variables and Secrets, tipo «Secret»):
//   HOOK_SECRET      il segreto generato da Supabase per l'hook (inizia con v1,whsec_)
//   CINE_SMTP_PASS   la password della casella info@cinelegami.it
//   GIOCO_SMTP_PASS  la password della casella info@giocolegami.it
//   PROVA_CHIAVE     una parola a scelta, serve solo per la pagina di prova
// Facoltative (se le caselle hanno un altro nome): CINE_FROM, GIOCO_FROM

import { connect } from "cloudflare:sockets";

const SUPABASE = "https://ezswtznereojtyphdbfh.supabase.co";
const SMTP_HOST = "smtps.aruba.it";
const SMTP_PORT = 465;

const SITI = {
  cine: {
    nome: "CineLegami", url: "https://cinelegami.it/", colore: "#2f9a7a", altro: "GiocoLegami",
    from: (env) => env.CINE_FROM || "info@cinelegami.it", pass: (env) => env.CINE_SMTP_PASS,
  },
  gioco: {
    nome: "GiocoLegami", url: "https://giocolegami.it/", colore: "#e0412b", altro: "CineLegami",
    from: (env) => env.GIOCO_FROM || "info@giocolegami.it", pass: (env) => env.GIOCO_SMTP_PASS,
  },
};
const sitoDa = (redirect) => (/giocolegami/i.test(String(redirect || "")) ? "gioco" : "cine");

const enc = new TextEncoder();
function b64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
const b64t = (t) => b64(enc.encode(String(t)));
const b64dec = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// ---- firma di Supabase (Standard Webhooks) ----
async function firmaValida(req, body, secret) {
  const id = req.headers.get("webhook-id"), ts = req.headers.get("webhook-timestamp"), sig = req.headers.get("webhook-signature") || "";
  if (!id || !ts || !secret) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;
  const key = await crypto.subtle.importKey("raw", b64dec(secret.replace(/^v1,/, "").replace(/^whsec_/, "")), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = b64(new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(id + "." + ts + "." + body))));
  return sig.split(" ").some((p) => p.split(",")[1] === mac);
}

// ---- spedizione con il server SMTP di Aruba ----
async function smtp({ user, pass, fromName, to, subject, text, html }) {
  if (!pass) throw new Error("manca la password della casella " + user);
  const sock = connect({ hostname: SMTP_HOST, port: SMTP_PORT }, { secureTransport: "on" });
  const w = sock.writable.getWriter(), r = sock.readable.getReader(), dec = new TextDecoder();
  let buf = "";
  const leggi = async () => {
    for (;;) {
      const righe = buf.split("\r\n");
      for (let i = 0; i < righe.length - 1; i++) {
        if (/^\d{3}( |$)/.test(righe[i])) {
          const risposta = righe.slice(0, i + 1);
          buf = righe.slice(i + 1).join("\r\n");
          return { code: Number(righe[i].slice(0, 3)), text: risposta.join(" | ") };
        }
      }
      const { value, done } = await r.read();
      if (done) throw new Error("il server di posta ha chiuso la connessione");
      buf += dec.decode(value, { stream: true });
    }
  };
  const cmd = async (riga, attesi, mostra) => {
    if (riga !== null) await w.write(enc.encode(riga + "\r\n"));
    const x = await leggi();
    if (!attesi.includes(x.code)) throw new Error("SMTP " + (mostra || riga || "saluto") + ": " + x.text);
    return x;
  };
  const corpo = (t) => b64t(t).replace(/.{1,76}/g, "$&\r\n");
  const confine = "legami-" + crypto.randomUUID();
  const msg = [
    "From: =?UTF-8?B?" + b64t(fromName) + "?= <" + user + ">",
    "To: <" + to + ">",
    "Subject: =?UTF-8?B?" + b64t(subject) + "?=",
    "Date: " + new Date().toUTCString().replace("GMT", "+0000"),
    "Message-ID: <" + crypto.randomUUID() + "@" + user.split("@")[1] + ">",
    "MIME-Version: 1.0",
    'Content-Type: multipart/alternative; boundary="' + confine + '"',
    "",
    "--" + confine,
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    corpo(text),
    "--" + confine,
    "Content-Type: text/html; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
    "",
    corpo(html),
    "--" + confine + "--",
    "",
  ].join("\r\n");
  const lavoro = (async () => {
    await cmd(null, [220]);
    await cmd("EHLO legami-posta.workers.dev", [250]);
    await cmd("AUTH LOGIN", [334]);
    await cmd(b64t(user), [334], "utente");
    await cmd(b64t(pass), [235], "password");
    await cmd("MAIL FROM:<" + user + ">", [250]);
    await cmd("RCPT TO:<" + to + ">", [250, 251]);
    await cmd("DATA", [354]);
    await cmd(msg + "\r\n.", [250], "invio del messaggio");
    try { await cmd("QUIT", [221]); } catch (e) {}
  })();
  try {
    await Promise.race([lavoro, new Promise((_, ko) => setTimeout(() => ko(new Error("il server di posta non risponde")), 20000))]);
  } finally {
    try { await sock.close(); } catch (e) {}
  }
}

// ---- testi delle email ----
function email(sito, tipo, link, codice) {
  const S = SITI[sito];
  const T = {
    signup: ["Conferma il tuo account " + S.nome, "Benvenuto su " + S.nome + "!", "Per attivare il tuo account conferma la tua email con il pulsante qui sotto.", "Conferma la tua email"],
    recovery: ["Scegli una nuova password per " + S.nome, "Nuova password", "Hai chiesto di cambiare la password del tuo account. Premi il pulsante e scegline una nuova.", "Scegli la nuova password"],
    magiclink: ["Il tuo link di accesso a " + S.nome, "Accedi a " + S.nome, "Premi il pulsante per entrare nel tuo account.", "Accedi"],
    invite: ["Sei stato invitato su " + S.nome, "Ti aspettiamo su " + S.nome, "Premi il pulsante per accettare l'invito e creare il tuo account.", "Accetta l'invito"],
    email_change: ["Conferma il cambio di email su " + S.nome, "Cambio di email", "Premi il pulsante per confermare il nuovo indirizzo email del tuo account.", "Conferma"],
    reauthentication: ["Il tuo codice di verifica per " + S.nome, "Codice di verifica", "Usa questo codice per confermare l'operazione:", ""],
  }[tipo] || ["Messaggio da " + S.nome, S.nome, "Premi il pulsante per continuare.", "Continua"];
  const [oggetto, titolo, frase, bottone] = T;
  const nota = "Lo stesso account vale su " + S.nome + " e su " + S.altro + ".";
  const ignora = "Se non sei stato tu, ignora questa email: non succederà niente.";
  const azione = link
    ? `<p style="margin:26px 0"><a href="${esc(link)}" style="display:inline-block;background:${S.colore};color:#ffffff;text-decoration:none;font-weight:700;padding:13px 26px;border-radius:999px">${esc(bottone)}</a></p><p style="font-size:13px;color:#8a8478">Se il pulsante non funziona, copia questo indirizzo nel browser:<br><a href="${esc(link)}" style="color:#8a8478;word-break:break-all">${esc(link)}</a></p>`
    : `<p style="margin:24px 0;font-size:30px;font-weight:800;letter-spacing:6px">${esc(codice)}</p>`;
  const html = `<!doctype html><html lang="it"><body style="margin:0;background:#f4f1ea;font-family:Arial,Helvetica,sans-serif;color:#1d1b18">
<div style="max-width:520px;margin:0 auto;padding:28px 18px">
<div style="background:#ffffff;border-radius:16px;padding:28px 26px;border-top:6px solid ${S.colore}">
<p style="margin:0 0 18px;font-size:22px;font-weight:800;color:${S.colore}">${esc(S.nome)}</p>
<h1 style="margin:0 0 12px;font-size:21px">${esc(titolo)}</h1>
<p style="margin:0;font-size:15px;line-height:1.5">${esc(frase)}</p>
${azione}
<p style="font-size:13px;color:#8a8478;line-height:1.5">${esc(nota)} ${esc(ignora)}</p>
</div>
<p style="text-align:center;font-size:12px;color:#8a8478;margin-top:16px"><a href="${S.url}" style="color:#8a8478">${S.url.replace(/^https:\/\/|\/$/g, "")}</a></p>
</div></body></html>`;
  const text = `${titolo}\n\n${frase}\n\n${link || codice}\n\n${nota}\n${ignora}\n\n${S.nome} · ${S.url}`;
  return { oggetto, html, text };
}

const verifica = (hash, tipo, redirect) =>
  SUPABASE + "/auth/v1/verify?token=" + encodeURIComponent(hash) + "&type=" + encodeURIComponent(tipo) + "&redirect_to=" + encodeURIComponent(redirect || "");

async function spedisci(env, sito, to, tipo, link, codice) {
  const S = SITI[sito], m = email(sito, tipo, link, codice);
  await smtp({ user: S.from(env), pass: S.pass(env), fromName: S.nome, to, subject: m.oggetto, text: m.text, html: m.html });
}

const json = (o, status) => new Response(JSON.stringify(o), { status: status || 200, headers: { "Content-Type": "application/json" } });

export default {
  async fetch(req, env) {
    const url = new URL(req.url);

    // Prova: indirizzo del Worker + /prova?chiave=PROVA_CHIAVE&sito=gioco&a=tua@email.it
    if (req.method === "GET" && url.pathname === "/prova") {
      if (!env.PROVA_CHIAVE || url.searchParams.get("chiave") !== env.PROVA_CHIAVE) return new Response("Chiave mancante o sbagliata", { status: 403 });
      const sito = url.searchParams.get("sito") === "gioco" ? "gioco" : "cine", a = url.searchParams.get("a") || "";
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(a)) return new Response("Indirizzo email non valido", { status: 400 });
      try {
        await spedisci(env, sito, a, "signup", SITI[sito].url, "");
        return new Response("Email di prova spedita da " + SITI[sito].from(env) + " a " + a + ". Controlla la posta (anche lo spam).");
      } catch (e) {
        return new Response("Spedizione non riuscita: " + e.message, { status: 502 });
      }
    }

    if (req.method !== "POST") return new Response("legami-posta: servizio attivo", { status: 200 });
    const body = await req.text();
    if (!(await firmaValida(req, body, env.HOOK_SECRET))) return json({ error: { http_code: 401, message: "Firma non valida" } }, 401);

    let d;
    try { d = JSON.parse(body); } catch (e) { return json({ error: { http_code: 400, message: "Richiesta non valida" } }, 400); }
    const user = d.user || {}, ed = d.email_data || {}, tipo = ed.email_action_type || "", redirect = ed.redirect_to || ed.site_url || "";
    const sito = sitoDa(redirect);
    try {
      if (tipo === "reauthentication") {
        await spedisci(env, sito, user.email, tipo, "", ed.token);
      } else if (tipo === "email_change" && ed.token_hash_new && user.new_email) {
        // cambio email con doppia conferma: un link al vecchio indirizzo e uno al nuovo
        await spedisci(env, sito, user.email, tipo, verifica(ed.token_hash_new, tipo, redirect));
        await spedisci(env, sito, user.new_email, tipo, verifica(ed.token_hash, tipo, redirect));
      } else {
        const to = tipo === "email_change" && user.new_email ? user.new_email : user.email;
        await spedisci(env, sito, to, tipo, verifica(ed.token_hash, tipo, redirect));
      }
      return json({});
    } catch (e) {
      return json({ error: { http_code: 500, message: "Email non spedita: " + e.message } }, 500);
    }
  },
};
