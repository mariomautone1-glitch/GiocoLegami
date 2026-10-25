# GiocoLegami

Scegli un videogioco e scopri come è legato ad altri giochi attraverso gli studi di sviluppo, gli editori e i generi che condividono.
Cerca un gioco, uno studio o un editore. Nel grafo un tocco evidenzia i legami, due tocchi aprono i dettagli.
Segna i giochi che hai giocato nella lista «I miei giochi»: senza account resta sul tuo dispositivo.

- **Sito:** https://giocolegami.it/ (indirizzo di riserva: https://mariomautone1-glitch.github.io/giocolegami/)
- **Dati e immagini:** [IGDB.com](https://www.igdb.com), tramite il servizio Cloudflare `giocolegami`, che tiene nascoste le credenziali Twitch.

## File

- `index.html`: tutto il sito. L'indirizzo del servizio Cloudflare è alla riga `const API=...`.
- `logo-scritta.png` e `logo-simbolo.png`: il logo.
- `manifest.webmanifest`, `sw.js` e le tre icone: servono per installare il sito sul telefono come un'app.
- `info.html` e `privacy.html`: le pagine «Cos'è GiocoLegami» e l'informativa privacy (con `mario.jpg`).
- `robots.txt`, `sitemap.xml`, `LICENSE`: per i motori di ricerca e il copyright.
- `giocolegami-supabase.sql`: crea nel database le tabelle per giochi, voti e recensioni (da eseguire una volta).
- `giocolegami-supabase-2.sql`: aggiunge segnalazioni e utenti bloccati (da eseguire una volta, dopo il primo).
- `giocolegami-supabase-3.sql`: aggiunge i consigli alla community e i giochi simili secondo la community (da eseguire una volta, dopo il secondo).

## Account, voti e recensioni

GiocoLegami usa lo stesso progetto Supabase di CineLegami: un solo account vale per entrambi i siti.

1. Supabase, SQL Editor, New query: incolla `giocolegami-supabase.sql` e premi Run. Poi fai lo stesso con `giocolegami-supabase-2.sql` e infine con `giocolegami-supabase-3.sql`.
2. Supabase, Authentication, URL Configuration, Redirect URLs: aggiungi `https://giocolegami.it/` e `https://www.giocolegami.it/`.
   Serve perché i link delle email (conferma e nuova password) riportino su GiocoLegami.

Il servizio risponde solo alle richieste che arrivano da `https://giocolegami.it`, `https://www.giocolegami.it` e `https://mariomautone1-glitch.github.io`.

`CNAME` dice a GitHub Pages di usare il dominio giocolegami.it.

## Prima di guadagnarci

IGDB è gratuito, ma per i progetti commerciali chiede un accordo. Va contattato prima di mettere pubblicità o abbonamenti.
