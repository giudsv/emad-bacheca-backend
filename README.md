# EMAD – Bacheca annunci di lavoro · Back-end

Server REST scritto in **Dart** con [shelf](https://pub.dev/packages/shelf), che fa da back-end per l'app Flutter
[emad-bacheca-app](https://github.com/giudsv/emad-bacheca-app).

Non usa servizi esterni: i dati sono salvati in locale e restano disponibili anche dopo il riavvio del server.

- `data/db.json`: aziende, annunci, candidature e sessioni
- `data/cv/`: i curriculum PDF caricati dai candidati

## Avvio

Serve il [Dart SDK](https://dart.dev/get-dart) (è incluso in Flutter).

```bash
dart pub get
dart run bin/server.dart
```

Il server ascolta su tutte le interfacce, porta **8080**, e all'avvio stampa gli indirizzi a cui l'app può collegarsi:

| Dove gira l'app | Indirizzo del server da usare nell'app |
|---|---|
| Emulatore Android | `http://10.0.2.2:8080` |
| Smartphone fisico (stessa rete Wi-Fi del PC) | `http://<IP del PC>:8080`, es. `http://192.168.1.19:8080` |

> Su Windows, al primo avvio, consenti l'accesso a Dart nel firewall per le **reti private**, altrimenti lo smartphone
> non riesce a raggiungere il server.

Variabili d'ambiente opzionali: `PORT` (default `8080`) e `DATA_DIR` (default `data`).

## API

Le risposte sono in JSON. Gli errori hanno la forma `{"errore": "...", "campi": {...}}`.
Le API dell'area riservata richiedono l'header `Authorization: Bearer <token>`, ottenuto con il login.

| Metodo | Endpoint | Accesso | Descrizione | Req. |
|---|---|---|---|---|
| POST | `/api/auth/registrazione` | pubblico | Crea l'account di un'azienda (`nome`, `email`, `password`) | R1 |
| POST | `/api/auth/login` | pubblico | Login con `email` e `password`, restituisce il token | R2 |
| POST | `/api/auth/logout` | azienda | Invalida il token di sessione | R3 |
| GET | `/api/auth/me` | azienda | Dati dell'azienda autenticata | – |
| POST | `/api/annunci` | azienda | Pubblica un annuncio (`titolo`, `descrizione`, `luogo`, `tipoContratto`) | R4 |
| GET | `/api/annunci` | pubblico | Elenco degli annunci della bacheca | R5 |
| GET | `/api/annunci/{id}` | pubblico | Dettaglio di un annuncio | R5 |
| POST | `/api/annunci/{id}/candidature` | pubblico | Candidatura `multipart/form-data`: `nome`, `cognome`, `email`, `telefono`, `messaggio`, file `cv` (PDF, max 10 MB) | R6 |
| GET | `/api/me/annunci` | azienda | Annunci dell'azienda, con il numero di candidature | R7 |
| GET | `/api/annunci/{id}/candidature` | azienda proprietaria | Candidature ricevute per un annuncio | R7 |
| GET | `/api/candidature/{id}` | azienda proprietaria | Dettaglio di una candidatura | R7 |
| GET | `/api/candidature/{id}/cv` | azienda proprietaria | Scarica il curriculum PDF | R7 |

### Sicurezza

- Le password non vengono salvate in chiaro: si conserva un hash SHA-256 con sale casuale e 10.000 iterazioni.
- Il token di sessione è casuale (256 bit) e viene invalidato al logout.
- Un'azienda vede solo le candidature dei propri annunci (in caso contrario risponde `403`).
- Il curriculum deve essere un vero PDF: il server ne controlla la firma `%PDF`.

## Struttura

```
bin/server.dart      # Avvio del server HTTP
lib/server.dart      # Router e gestione delle API
lib/database.dart    # Archivio persistente su file JSON
test/api_test.dart   # Test end-to-end degli scenari S1–S3 e della persistenza
```

## Test

```bash
dart test
```
